import AppKit
import Combine
import SwiftUI

/// The first launch: bring macOS's Dock along, let Petal see windows, then Petal takes the Dock's place.
/// "Not now" keeps macOS's Dock; Petal's settings can switch any time.
@MainActor
final class Welcome {
    private var window: NSWindow?
    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        PetalApp.shared.refreshSystemFacts()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: WelcomeView.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setGlassContent(WelcomeView { [weak self] in self?.window?.close() }.environment(PetalApp.shared))
        window.letContentGoWhenClosed()
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
    /// Checked every second; the window draws again only when one changes.
    @State private var trusted = Windows.trusted
    @State private var capture = Capture.allowed
    @State private var askingBrowsers = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let browsersTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    static let height: CGFloat = 780

    var body: some View {
        let accent = SettingsSection.dock.tint
        ZStack {
            Backdrop()
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                VStack(spacing: 6) {
                    Text("Meet Petal").font(.system(size: 32, weight: .bold))
                    Text("A dock with your notes on it, and AI built in if you want it.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        step(symbol: "dock.rectangle", title: "Bring your Dock along",
                             detail: "Your Dock's apps become Petal's, in the same order, and its folders become stacks.") {
                            Toggle("", isOn: $bringDock).toggleStyle(.switch).labelsHidden()
                        } extra: {
                            HStack(spacing: -6) {
                                ForEach(app.systemDockApps.prefix(10), id: \.self) { id in
                                    Image(nsImage: Apps.icon(id)).resizable().frame(width: 30, height: 30)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("AI").font(.system(size: 14, weight: .semibold))
                                Text("Optional. Without it, Petal is still a whole dock.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ProviderList()
                        }
                        .padding(14).frame(width: 520).glassEffect(.regular, in: .rect(cornerRadius: 20))
                        step(symbol: "macwindow.on.rectangle", title: "Let Petal see your windows",
                             detail: "For window lists, badges and notes on windows. macOS asks once.") {
                            if trusted {
                                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .medium))
                            } else {
                                Button("Allow…") { Windows.askForPermission() }.buttonStyle(.glass)
                            }
                        } extra: { EmptyView() }
                        step(symbol: "safari", title: "Let Petal see your tabs",
                             detail: "Optional. Which site a tab is on, for notes on a tab and for Petal AI. Each browser asks once.") {
                            BrowserAccessButton(asking: $askingBrowsers)
                        } extra: { EmptyView() }
                        step(symbol: "rectangle.dashed.badge.record", title: "Window previews",
                             detail: "Optional. A still of each window when you hover its app.") {
                            if capture {
                                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .medium))
                            } else {
                                Button("Allow…") { Capture.askForPermission() }.buttonStyle(.glass)
                            }
                        } extra: { EmptyView() }
                    }
                }
                Toggle("Open Petal at login", isOn: $atLogin).toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 12) {
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
                    .tint(accent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                Text("You can switch back any time in Petal’s settings.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .frame(width: 640, height: Self.height)
        .onReceive(timer) { _ in
            let nowTrusted = Windows.trusted, nowCapture = Capture.allowed
            if nowTrusted != trusted { trusted = nowTrusted }
            if nowCapture != capture { capture = nowCapture }
        }
        .onReceive(browsersTimer) { _ in app.browsers.refresh() }
        .task {
            // Start with the AIs already on this Mac switched on, and none otherwise: it's optional.
            guard !Headless.on else { return }   // a benchmark changes no setting by itself
            for provider in Provider.allCases { await app.lookFor(provider) }
            app.config.set("aiProviders", Provider.allCases.filter { app.paths[$0] != nil }.map(\.rawValue))
            app.aiSetup.refreshAll()
        }
    }

    private func step<Trailing: View, Extra: View>(symbol: String, title: String, detail: String,
                                                    @ViewBuilder trailing: () -> Trailing, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 40, height: 40).glassEffect(.regular, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                trailing()
            }
            extra()
        }
        .padding(14)
        .frame(width: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Allowed, Allow…, or Open Settings… for a browser that said no. Each browser asks once, from this button only.
struct BrowserAccessButton: View {
    @Environment(PetalApp.self) private var app
    @Binding var asking: Bool

    var body: some View {
        let browsers = app.browsers
        if asking {
            ProgressView().controlSize(.small)
        } else if !browsers.refused.isEmpty {
            Button("Open Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.glass)
        } else if browsers.allAllowed || Browsers.installed().isEmpty {
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .medium))
        } else {
            Button("Allow…") {
                asking = true
                browsers.askAll { asking = false }
            }
            .buttonStyle(.glass)
        }
    }
}

/// One AI app: whether Petal uses it, its state, and the one thing to do next (install it, sign in, or nothing).
struct ProviderRow: View {
    @Environment(PetalApp.self) private var app
    let provider: Provider
    @Binding var on: Bool

    var body: some View {
        let setup = app.aiSetup
        let state = setup.state(provider)
        // On an API key, being signed in doesn't matter: the key does (Settings › AI has its field).
        let keyed: Bool? = switch state {
        case .signedOut, .ready: app.usesAPIKey(provider) ? app.apiKeyCheck.savedKey(provider) != nil : nil
        default: nil
        }
        HStack(spacing: 14) {
            ProviderMark(provider: provider).frame(width: 20, height: 20).frame(width: 40, height: 40).glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.system(size: 14, weight: .semibold))
                Text(!on ? provider.plan : keyed.map { $0 ? "Uses your \(provider.keyMaker) API key." : "Add your \(provider.keyMaker) API key to use it." } ?? detail(state))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if on, let keyed {
                Image(systemName: keyed ? "checkmark.circle.fill" : "key").foregroundStyle(keyed ? .green : .secondary)
            } else if on {
                switch state {
                case .checking, .installing, .signingIn:
                    ProgressView().controlSize(.small)
                case .missing:
                    Button("Install") { setup.install(provider) }.buttonStyle(.glassProminent).tint(SettingsSection.claude.tint)
                case .signedOut:
                    Button("Sign in…") { setup.signIn(provider) }.buttonStyle(.glassProminent).tint(SettingsSection.claude.tint)
                case .failed:
                    Button("Try again") { setup.refresh(provider) }.buttonStyle(.glass)
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    private func detail(_ state: AISetup.State) -> String {
        switch state {
        case .checking: "Looking for \(provider.appName)…"
        case .missing: "Petal installs \(provider.appName) for you. \(provider.plan)"
        case .installing: "Installing \(provider.appName)…"
        case .signedOut: "Sign in with your own account. \(provider.plan)"
        case .signingIn: "Finish signing in in your browser."
        case .ready(let email): email.isEmpty ? "Ready." : "Signed in as \(email)."
        case .failed(let text): text
        }
    }
}

/// The AI apps as switches, saved in aiProviders; none is fine.
struct ProviderList: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Provider.allCases) { provider in
                ProviderRow(provider: provider, on: Binding(
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
