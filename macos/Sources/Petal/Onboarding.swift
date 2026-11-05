import AppKit
import Combine
import SwiftUI

/// The first launch: bring macOS's Dock along as a mode, let Petal see windows, then Petal takes the Dock's place.
/// "Not now" keeps macOS's Dock; Petal's settings can switch any time.
@MainActor
final class Welcome {
    private var window: NSWindow?

    func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in self?.window?.close() }.environment(PetalApp.shared))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    @Environment(PetalApp.self) private var app
    let done: () -> Void
    @State private var bringDock = true
    @State private var atLogin = true
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let accent = SettingsSection.dock.tint
        ZStack {
            Wallpaper()
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                VStack(spacing: 6) {
                    Text("Meet Petal").font(.system(size: 32, weight: .bold))
                    Text("A dock with a focus mode for every Desktop, and Claude built in.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        step(symbol: "dock.rectangle", title: "Bring your Dock along",
                             detail: "Your Dock's apps become a mode, My Dock, and its folders become stacks.") {
                            Toggle("", isOn: $bringDock).toggleStyle(.switch).labelsHidden()
                        } extra: {
                            HStack(spacing: -6) {
                                ForEach(SystemDock.apps().prefix(10), id: \.self) { id in
                                    Image(nsImage: Apps.icon(id)).resizable().frame(width: 30, height: 30)
                                }
                            }
                        }
                        step(symbol: "macwindow.on.rectangle", title: "Let Petal see your windows",
                             detail: "For window lists, badges and focus cards. macOS asks once.") {
                            let _ = tick
                            if Windows.trusted {
                                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .medium))
                            } else {
                                Button("Allow…") { Windows.askForPermission() }.buttonStyle(.glass)
                            }
                        } extra: { EmptyView() }
                        step(symbol: "rectangle.dashed.badge.record", title: "Window previews",
                             detail: "Optional. A still of each window when you hover its app.") {
                            let _ = tick
                            if Capture.allowed {
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
            .padding(36)
        }
        .frame(width: 640, height: 640)
        .onReceive(timer) { _ in tick += 1 }
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
