import AppKit
import Combine
import SwiftUI

/// The first launch: what Petal is, as its four parts in their colors, then only what has to be decided now (the
/// Dock's apps, which AI, seeing windows, opening at login). "Use Petal" takes the Dock's place; "Keep macOS's Dock"
/// leaves it, as closing the window does, and Petal's settings can switch any time. Everything else Petal may be
/// allowed (pictures of windows, browsers' tabs, what's playing) is asked where it's first used, never here.
@MainActor
final class Welcome {
    private var window: NSWindow?
    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        PetalApp.shared.refreshSystemFacts()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WelcomeView.width, height: WelcomeView.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setGlassContent(WelcomeView { [weak self] in self?.window?.close() }.environment(PetalApp.shared))
        window.letContentGoWhenClosed()
        // Closed with its own button, without choosing: as "Keep macOS's Dock", so the welcome doesn't come back at
        // every launch with no dock meanwhile.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                let app = PetalApp.shared
                guard !app.config.welcomed else { return }
                app.config.setDock("welcomed", true)
                app.useDock("macos")
            }
        }
        window.center()
        self.window = window
        PetalWindow.bringForward(window)
    }
}

struct WelcomeView: View {
    @Environment(PetalApp.self) private var app
    let done: () -> Void
    @State private var bringDock = true
    @State private var atLogin = true
    /// Checked every second; the window draws again only when it changes.
    @State private var trusted = Windows.trusted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    static let width: CGFloat = 640
    static let height: CGFloat = 524

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    Text("Meet Petal").font(.system(size: TextSize.large, weight: .bold))
                }
                FourParts().padding(.top, 20)
                VStack(spacing: 0) {
                    WelcomeRow(title: "Bring your Dock along") {
                        Image(systemName: "dock.rectangle")
                    } trailing: {
                        DockIcons()
                        Toggle("", isOn: $bringDock).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    ProviderList(welcome: true)
                    WelcomeRow(title: "Let Petal see your windows") {
                        Image(systemName: "macwindow.on.rectangle")
                    } trailing: {
                        if trusted {
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .font(.system(size: TextSize.callout, weight: .medium)).foregroundStyle(.green)
                        } else {
                            Button("Allow…") { Windows.askForPermission() }.buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    WelcomeRow(title: "Open Petal at login") {
                        Image(systemName: "power")
                    } trailing: {
                        Toggle("", isOn: $atLogin).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
                .padding(.top, 12)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Spacer()
                    Button("Keep macOS’s Dock") {
                        app.config.setDock("welcomed", true)
                        app.useDock("macos")
                        done()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    Button("Use Petal") {
                        if bringDock { app.config.importSystemDock() }
                        app.openAtLogin = atLogin
                        app.config.setDock("welcomed", true)
                        app.useDock("petal")
                        done()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Part.dock.color)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, WelcomeLook.margin)
            .padding(.top, 44)
            .padding(.bottom, 24)
        }
        .frame(width: Self.width, height: Self.height)
        .onReceive(timer) { _ in
            let now = Windows.trusted
            if now != trusted { trusted = now }
        }
        .task {
            // Start with the AIs already on this Mac switched on, and none otherwise: it's optional.
            guard !Headless.on else { return }   // a benchmark changes no setting by itself
            for provider in Provider.allCases { await app.lookFor(provider) }
            app.config.set("aiProviders", Provider.allCases.filter { app.paths[$0] != nil }.map(\.rawValue))
            app.aiSetup.refreshAll()
        }
    }
}

/// The welcome's measures, shared by its rows and the AI apps' rows (which Settings lists too).
enum WelcomeLook {
    static let margin: CGFloat = 32
    static let rowHeight: CGFloat = 38
    static let mark: CGFloat = 20
}

/// The Dock's own apps, small, in its order: what "Bring your Dock along" brings.
struct DockIcons: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        HStack(spacing: 2) {
            ForEach(app.systemDockApps.prefix(10), id: \.self) { id in
                Image(nsImage: snapshotting ? Self.flat(Apps.icon(id)) : Apps.icon(id)).resizable().frame(width: 24, height: 24)
            }
        }
    }

    /// An icon as plain pixels, for `Petal --snapshot` only: macOS's own icon images, drawn off-screen as they are
    /// on a Mac set to tinted icons, wash the whole drawing out.
    static func flat(_ icon: NSImage) -> NSImage {
        let side = 96
        guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let flat = NSImage(size: NSSize(width: 24, height: 24))
        flat.addRepresentation(pixels)
        return flat
    }
}

/// Petal's four parts as one strip of four colors, as the site's first screen has them: each part's mark, its name
/// and three words at most.
struct FourParts: View {
    static let parts: [(part: Part, name: String, words: String)] = [
        (.notes, "Notes", "Stick to anything"),
        (.ai, "Petal AI", "Asks before acting"),
        (.vault, "A vault", "Logins, cards, keys"),
        (.dock, "A dock", "Replaces your Dock"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.parts, id: \.part) { item in
                VStack(alignment: .leading, spacing: 2) {
                    PartMark(part: item.part, size: 26)
                    Spacer(minLength: 0)
                    Text(item.name).font(.system(size: TextSize.subtitle, weight: .semibold))
                    Text(item.words).font(.system(size: TextSize.callout, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(item.part.onColor)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(item.part.color)
            }
        }
        .frame(height: 128)
        .clipShape(.rect(cornerRadius: Radius.card))
    }
}

/// A part's line mark, the one the site's dock shows for it (notes, Petal AI, the vault, the dock), drawn in the
/// site's 24-point box and scaled to `size`; it takes the color of the text around it.
struct PartMark: View {
    let part: Part
    var size: CGFloat = 24

    var body: some View {
        let scale = size / 24
        let fit = CGAffineTransform(scaleX: scale, y: scale)
        ZStack {
            Self.lines(part).applying(fit).stroke(style: StrokeStyle(lineWidth: 1.7 * scale, lineCap: .round, lineJoin: .round))
            Self.solid(part).applying(fit).fill()
        }
        .frame(width: size, height: size)
    }

    /// What's drawn as a line.
    static func lines(_ part: Part) -> Path {
        var path = Path()
        switch part {
        case .notes:   // a paper with its corner folded
            path.move(to: CGPoint(x: 6, y: 5))
            path.addLine(to: CGPoint(x: 18, y: 5))
            path.addLine(to: CGPoint(x: 18, y: 14))
            path.addLine(to: CGPoint(x: 13.5, y: 19))
            path.addLine(to: CGPoint(x: 6, y: 19))
            path.closeSubpath()
            path.move(to: CGPoint(x: 18, y: 14))
            path.addLine(to: CGPoint(x: 13.5, y: 14))
            path.addLine(to: CGPoint(x: 13.5, y: 19))
        case .vault:   // a key
            path.addEllipse(in: CGRect(x: 5, y: 12, width: 7, height: 7))
            path.move(to: CGPoint(x: 11, y: 13))
            path.addLine(to: CGPoint(x: 18.5, y: 5.5))
            path.move(to: CGPoint(x: 15.5, y: 8.5))
            path.addLine(to: CGPoint(x: 18, y: 11))
        case .dock:    // the dock's bar
            path.addRoundedRect(in: CGRect(x: 3.5, y: 12.5, width: 17, height: 6.5), cornerSize: CGSize(width: 3.25, height: 3.25))
        default: break
        }
        return path
    }

    /// What's drawn filled.
    static func solid(_ part: Part) -> Path {
        var path = Path()
        switch part {
        case .ai:      // Petal's own pointer
            path.move(to: CGPoint(x: 6.5, y: 3.5))
            path.addLine(to: CGPoint(x: 6.5, y: 18.7))
            path.addLine(to: CGPoint(x: 10.6, y: 14.9))
            path.addLine(to: CGPoint(x: 12.8, y: 20.4))
            path.addLine(to: CGPoint(x: 15.6, y: 19.2))
            path.addLine(to: CGPoint(x: 13.4, y: 14))
            path.addLine(to: CGPoint(x: 18.3, y: 14.2))
            path.closeSubpath()
        case .dock:    // three apps on the bar
            for x in [7.8, 12, 16.2] { path.addEllipse(in: CGRect(x: x - 1.2, y: 14.55, width: 2.4, height: 2.4)) }
        default: break
        }
        return path
    }
}

/// One line of the welcome: a small mark, what it is, and its one control at the end.
struct WelcomeRow<Mark: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var mark: Mark
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            mark.font(.system(size: TextSize.heading)).foregroundStyle(.secondary)
                .frame(width: WelcomeLook.mark, height: WelcomeLook.mark)
            Text(title).font(.system(size: TextSize.body, weight: .medium))
            Spacer(minLength: 12)
            trailing
        }
        .frame(height: WelcomeLook.rowHeight)
    }
}

/// One AI app: whether Petal uses it, its state, and the one thing to do next (install it, sign in, or nothing).
struct ProviderRow: View {
    @Environment(PetalApp.self) private var app
    let provider: Provider
    var welcome = false
    @Binding var on: Bool

    var body: some View {
        let setup = app.aiSetup
        let state = setup.state(provider)
        // On an API key, being signed in doesn't matter: the key does (Settings › Petal AI has its field).
        let keyed: Bool? = switch state {
        case .signedOut, .ready: app.usesAPIKey(provider) ? app.apiKeyCheck.savedKey(provider) != nil : nil
        default: nil
        }
        HStack(spacing: 12) {
            ProviderMark(provider: provider).frame(width: WelcomeLook.mark, height: WelcomeLook.mark)
            Text(welcome ? (provider == .claude ? "Petal AI, with Claude" : "Petal AI, with ChatGPT (Codex)") : provider.name)
                .font(.system(size: TextSize.body, weight: .medium))
            Spacer(minLength: 12)
            // Before installing or signing in: whose plan it uses.
            if welcome, on, state == .missing || state == .signedOut {
                Text(provider.plan).font(.system(size: TextSize.small)).foregroundStyle(.secondary).lineLimit(1)
            }
            if on { ProviderStatus(provider: provider, state: state, keyed: keyed) }
            Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .frame(height: WelcomeLook.rowHeight)
    }
}

/// Where an AI app that's switched on stands, in a few words at most, and the one thing to do next.
struct ProviderStatus: View {
    @Environment(PetalApp.self) private var app
    let provider: Provider
    let state: AISetup.State
    /// On an API key: whether one is saved (nil: it uses the person's own sign-in).
    let keyed: Bool?

    var body: some View {
        let setup = app.aiSetup
        if let keyed {
            said(keyed ? "\(provider.keyMaker) API key" : "Needs your \(provider.keyMaker) API key")
            Image(systemName: keyed ? "checkmark.circle.fill" : "key").foregroundStyle(keyed ? .green : .secondary)
        } else {
            switch state {
            case .checking:
                ProgressView().controlSize(.small)
            case .installing:
                said("Installing…")
                ProgressView().controlSize(.small)
            case .signingIn:
                said("Finish signing in in your browser")
                ProgressView().controlSize(.small)
            case .missing:
                Button("Install") { setup.install(provider) }.buttonStyle(.glassProminent).tint(Part.ai.color).controlSize(.small)
            case .signedOut:
                Button("Sign in…") { setup.signIn(provider) }.buttonStyle(.glassProminent).tint(Part.ai.color).controlSize(.small)
            case .failed(let text):
                said(text)
                Button("Try again") { setup.refresh(provider) }.buttonStyle(.glass).controlSize(.small)
            case .ready(let email):
                if !email.isEmpty { said(email) }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func said(_ text: String) -> some View {
        Text(text).font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
            .lineLimit(2).multilineTextAlignment(.trailing).truncationMode(.middle)
    }
}

/// The AI apps as switches, saved in aiProviders; none is fine.
struct ProviderList: View {
    @Environment(PetalApp.self) private var app
    /// In the welcome, each row says what it is and that it uses the person's own plan.
    var welcome = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Provider.allCases) { provider in
                ProviderRow(provider: provider, welcome: welcome, on: Binding(
                    get: { app.providers.contains(provider) },
                    set: { on in
                        var chosen = app.providers.filter { $0 != provider }
                        if on { chosen.append(provider) }
                        app.config.set("aiProviders", Provider.allCases.filter(chosen.contains).map(\.rawValue))
                        if on { app.aiSetup.refresh(provider) }
                        app.docks.refresh()
                    }))
            }
        }
    }
}
