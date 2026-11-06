import AppKit
import Combine
import SwiftUI

/// Settings > Focus: focus cards, distracting modes, browser tabs and held notifications.
struct FocusSettings: View {
    var body: some View {
        Card(footer: "When what's in front belongs to another mode, a card says so: \"x.com · belongs to Social\". A distracting mode's apps and sites are blocked in the other modes; Stay closes the tab or hides the app.") {
            SettingToggle(key: "focusGuard", title: "Focus cards")
            SettingToggle(key: "blockDistractions", title: "Block distractions", detail: "Apps and sites of distracting modes, like Social, outside them.")
            SettingToggle(key: "peeks", title: "Peeks", detail: "A small card that fades by itself when the AI sorts something new.")
            SettingToggle(key: "countdown", title: "Wait to get into distracting modes", detail: "Each click on the mode halves the wait; Stay cancels.")
        }
        Card(title: "Browser tabs") { BrowserAccessRow() }
        HoldCard()
        HistoryCard()
    }
}

/// Held notifications: the settings, seeing notifications, and keeping macOS's banners away.
struct HoldCard: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        Card(title: "Notifications", footer: "In a mode that holds them, notifications from apps outside it wait on their own mode, with a count on its button. Petal shows the mode's own ones itself, above the dock.") {
            SettingToggle(key: "holdNotifications", title: "Hold notifications", detail: "Each mode chooses whether it holds them.")
            SettingToggle(key: "urgentNotifications", title: "Let urgent ones through", detail: "One that can't wait pops out of its mode. The AI decides.")
            NotificationAccessRow()
            QuietRow()
            let status = app.notes.status
            if status.wanted && !status.works && app.config.bool("holdNotifications") {
                Label("Petal holds nothing until then.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }
}

/// "Let Petal see notifications": Full Disk Access, which only System Settings can give, checked live.
struct NotificationAccessRow: View {
    @Environment(PetalApp.self) private var app

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        StepRow(symbol: "bell.badge", title: "Let Petal see notifications",
                detail: "To hold them in modes that hold them. macOS calls it Full Disk Access: turn Petal on there.") {
            if app.notes.canRead {
                AllowedLabel()
            } else {
                Button("Open Settings…") { Self.openSettings() }.buttonStyle(.glass)
            }
        }
    }
}

/// How Petal keeps macOS's banners away while it holds: Do Not Disturb, or closing them as they come.
struct QuietRow: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let quiet = app.notes.quiet
        StepRow(symbol: "moon.fill", title: "Keep macOS's banners away", detail: detail(quiet.way)) {
            if quiet.addingShortcut {
                ProgressView().controlSize(.small)
            } else if quiet.way == .shortcut {
                AllowedLabel(text: "Ready")
            } else {
                Button("Add Shortcut…") { quiet.addShortcut() }.buttonStyle(.glass)
            }
        }
    }

    private func detail(_ way: Quiet.Way?) -> String {
        switch way {
        case .shortcut: "The Petal Do Not Disturb shortcut turns on Do Not Disturb while a mode holds notifications."
        case .closer: "Petal closes macOS's banners as they come. Add Petal's Do Not Disturb shortcut so they don't show at all."
        case nil: "Add Petal's Do Not Disturb shortcut: Shortcuts asks once."
        }
    }
}

/// "Let Petal see your tabs": each browser asks once, from this button only.
struct BrowserAccessRow: View {
    @Environment(PetalApp.self) private var app
    @State private var asking = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let browsers = app.browsers
        let refused = browsers.refused
        StepRow(symbol: "safari", title: "Let Petal see your tabs",
                detail: refused.isEmpty
                    ? "To know which site a tab is on, and close a distracting one. Each browser asks once. Firefox and Zen need only Accessibility."
                    : "\(refused.joined(separator: ", ")) said no. Turn Petal on for \(refused.count == 1 ? "it" : "them") in System Settings, under Automation.") {
            BrowserAccessButton(asking: $asking)
        }
        .onAppear { browsers.refresh() }
        .onReceive(timer) { _ in browsers.refresh() }
    }
}

/// Allowed, Allow…, or Open Settings… for a browser that said no.
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
            AllowedLabel()
        } else {
            Button("Allow…") {
                asking = true
                browsers.askAll { asking = false }
            }
            .buttonStyle(.glass)
        }
    }
}

/// A step with a symbol, a title, a line of detail and what to do (a button, or "Allowed").
struct StepRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 36, height: 36).glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct AllowedLabel: View {
    var text = "Allowed"

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .medium))
    }
}
