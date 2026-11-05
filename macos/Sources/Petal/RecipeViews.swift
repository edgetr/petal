import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A shared dock (build.sh declares it in Info.plist).
    static let petalRecipe = UTType(exportedAs: "tech.edgetr.petal.recipe", conformingTo: .json)
}

/// Opening a .petal file: what it would add, first, then adding it.
@MainActor
final class RecipeWindow {
    private var window: NSWindow?

    func show(_ url: URL) {
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.title = "Add a shared dock"
            return window
        }()
        self.window = window
        window.contentView = NSHostingView(rootView: RecipeImportView(url: url) { [weak window] in window?.close() }.environment(PetalApp.shared))
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Picks a .petal file to add.
    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.petalRecipe]
        panel.message = "Choose a dock someone shared with you (a .petal file)."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        show(url)
    }
}

struct RecipeImportView: View {
    @Environment(PetalApp.self) private var app
    let url: URL
    let done: () -> Void
    @State private var plan: Recipe.Plan?

    init(url: URL, plan: Recipe.Plan? = nil, done: @escaping () -> Void) {
        self.url = url
        self.done = done
        _plan = State(initialValue: plan)
    }
    @State private var problem = ""
    @State private var useLook = false
    @State private var added = false

    var body: some View {
        ZStack {
            Wallpaper()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(for: .petalRecipe)).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan?.name ?? url.deletingPathExtension().lastPathComponent).font(.system(size: 22, weight: .bold))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let plan {
                    Scroll {
                        GlassEffectContainer(spacing: 10) {
                            VStack(spacing: 10) {
                                ForEach(plan.modes) { mode in RecipeModeRow(mode: mode) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 360)
                    lookCard(plan)
                    buttons(plan)
                } else if !problem.isEmpty {
                    Text(problem).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Close", action: done).buttonStyle(.glass) }
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 40)
                }
            }
            .padding(28)
            .padding(.top, 10)
        }
        .frame(width: 600)
        .task {
            guard plan == nil else { return }
            let url = url
            do { plan = try await Task.detached { try Recipe.plan(url) }.value } catch { problem = error.localizedDescription }
        }
    }

    private var subtitle: String {
        guard let plan else { return "A shared Petal dock" }
        let place = plan.from == "omarchy" ? " from Omarchy" : plan.from == "macos" ? " from a Mac" : ""
        if added { return "Added. Put a Desktop in a new mode from the mode switcher." }
        return "A shared Petal dock\(place). It adds \(plan.modes.count == 1 ? "one mode" : "\(plan.modes.count) modes"); yours stay as they are."
    }

    @ViewBuilder private func lookCard(_ plan: Recipe.Plan) -> some View {
        if !plan.lookChanges.isEmpty {
            Card {
                Toggle(isOn: $useLook) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use this look too")
                        Text("Changes " + Insights.list(plan.lookChanges.map { Recipe.lookNames[$0] ?? $0 }) + ".")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small).disabled(added)
            }
        }
    }

    private func buttons(_ plan: Recipe.Plan) -> some View {
        HStack {
            if !plan.missing.isEmpty && !added {
                Text("Apps not on this Mac are left out.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if added {
                Button("Show in Settings") { done(); app.settings.show(.modes) }.buttonStyle(.glass)
                Button("Done", action: done).buttonStyle(.glassProminent).tint(SettingsSection.dock.tint).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: done).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(plan.modes.count == 1 ? "Add it" : "Add \(plan.modes.count) modes") {
                    do { try Recipe.apply(plan, look: useLook); added = true } catch { problem = error.localizedDescription }
                }
                .buttonStyle(.glassProminent).tint(SettingsSection.dock.tint).keyboardShortcut(.defaultAction)
                .disabled(plan.modes.isEmpty)
            }
        }
    }
}

struct RecipeModeRow: View {
    let mode: Recipe.PlannedMode

    var body: some View {
        let color = Color(nsColor: NSColor(hex: mode.color) ?? .systemPink)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ModeIcon(icon: mode.icon, size: 14).foregroundStyle(color)
                    .frame(width: 32, height: 32).glassEffect(.regular, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.name).font(.system(size: 14, weight: .semibold))
                    if !mode.about.isEmpty { Text(mode.about).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            HStack(spacing: 4) {
                ForEach(mode.apps.prefix(10), id: \.self) { id in
                    Image(nsImage: Apps.icon(id)).resizable().frame(width: 26, height: 26).help(Apps.name(id))
                }
                if mode.apps.isEmpty { Text("No apps on this Mac yet").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if !mode.missing.isEmpty {
                Text("Not on this Mac: " + mode.missing.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// "Share my dock…": save a .petal file, then macOS's share sheet (AirDrop, Messages, Mail).
struct ShareDockCard: View {
    @Environment(PetalApp.self) private var app
    @State private var anchor = ViewAnchor()
    @State private var saved: URL?
    @State private var problem = ""

    var body: some View {
        Card(title: "Share", footer: "A .petal file with your modes, their apps and your dock's look: nothing personal. Opening it on another Mac, or on Omarchy, adds the modes there.") {
            HStack {
                Button("Share my dock…", action: share).buttonStyle(.glassProminent).tint(SettingsSection.modes.tint)
                    .background(AnchorView(anchor: anchor))
                Button("Add a shared dock…") { app.recipes.choose() }.buttonStyle(.glass)
            }
            if let saved {
                HStack(spacing: 6) {
                    Text("Saved \(saved.lastPathComponent)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(SettingsSection.modes.tint)
                }
            }
            if !problem.isEmpty { Text(problem).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private func share() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.petalRecipe]
        panel.nameFieldStringValue = "My dock.petal"
        panel.message = "Your modes and look, to share."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let path = try Recipe.export(path: url.path, name: url.deletingPathExtension().lastPathComponent)
            let file = URL(fileURLWithPath: path)
            saved = file
            problem = ""
            if let view = anchor.view {
                NSSharingServicePicker(items: [file]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
        } catch {
            problem = "Couldn't save it: \(error.localizedDescription)"
        }
    }
}

/// An AppKit view to show AppKit popovers (the share sheet) from.
final class ViewAnchor {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
