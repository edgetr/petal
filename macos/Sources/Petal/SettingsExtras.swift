import AppKit
import SwiftUI

// The settings window's newer cards: keyboard shortcuts, the schedule, building modes with AI, suggestions, the
// activity history, and a mode's Shortcut.

/// A key combination, drawn as keys.
struct KeyCaps: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.14)))
    }
}

struct ShortcutsCard: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        Card(title: "Keyboard shortcuts", footer: "They work in any app. A combination macOS or another app already uses is left to it.") {
            SettingToggle(key: "shortcuts", title: "Keyboard shortcuts")
            if app.config.bool("shortcuts") {
                let keys = app.hotkeys.keys
                ForEach(keys) { key in
                    HStack(spacing: 10) {
                        KeyCaps(text: key.label).frame(width: 74, alignment: .leading)
                        what(key)
                        Spacer()
                        if app.hotkeys.taken.contains(key.id) {
                            Text("In use elsewhere").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func what(_ key: Hotkeys.Key) -> some View {
        switch key.id {
        case Hotkeys.ask:
            Text("Open \(app.chatProvider?.name ?? "the AI")").font(.system(size: 12))
        case Hotkeys.search:
            Text("Add apps to this Desktop’s mode").font(.system(size: 12))
        default:
            let modes = app.config.modes
            if Int(key.id) <= modes.count {
                let mode = modes[Int(key.id) - 1]
                HStack(spacing: 6) {
                    ModeIcon(icon: mode.icon, size: 11).foregroundStyle(Color(nsColor: mode.color)).frame(width: 16)
                    Text("Put this Desktop in \(mode.name)").font(.system(size: 12))
                }
            }
        }
    }
}

// MARK: - Schedule

struct ScheduleCard: View {
    @Environment(PetalApp.self) private var app
    static let days = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let blocks = app.automation.blocks
        Card(title: "Schedule", footer: blocks.isEmpty
             ? "Modes by the clock, if you like: when a time starts, the Desktop in front switches to its mode, once."
             : "When a time starts, the Desktop in front switches to its mode, once. You can switch away any time.") {
            ForEach(blocks.indices, id: \.self) { index in
                ScheduleRow(block: blocks[index]) { changed in
                    var all = blocks
                    if let changed { all[index] = changed } else { all.remove(at: index) }
                    app.automation.save(all)
                }
            }
            Button(blocks.isEmpty ? "Add a time…" : "Add another time") {
                let mode = app.config.modes.first?.id ?? ""
                app.automation.save(blocks + [ModeAutomation.Block(mode: mode, days: [1, 2, 3, 4, 5], from: "09:00", to: "17:00")])
            }
            .buttonStyle(.glass)
            .disabled(app.config.modes.isEmpty)
        }
    }
}

struct ScheduleRow: View {
    @Environment(PetalApp.self) private var app
    let block: ModeAutomation.Block
    let change: (ModeAutomation.Block?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { block.mode }, set: { var b = block; b.mode = $0; change(b) })) {
                ForEach(app.config.modes) { mode in Text(mode.name).tag(mode.id) }
            }
            .labelsHidden()
            .frame(width: 130)
            HStack(spacing: 2) {
                ForEach(1...7, id: \.self) { day in
                    let on = block.days.contains(day)
                    Button {
                        var b = block
                        if on { b.days.removeAll { $0 == day } } else { b.days.append(day) }
                        change(b)
                    } label: {
                        Text(ScheduleCard.days[day - 1]).font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(on ? AnyShapeStyle(SettingsSection.modes.tint) : AnyShapeStyle(.white.opacity(0.08)), in: .circle)
                            .foregroundStyle(on ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            DatePicker("", selection: time(\.from), displayedComponents: .hourAndMinute).labelsHidden()
            Text("to").foregroundStyle(.secondary)
            DatePicker("", selection: time(\.to), displayedComponents: .hourAndMinute).labelsHidden()
            Spacer(minLength: 0)
            Button { change(nil) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
    }

    private func time(_ path: WritableKeyPath<ModeAutomation.Block, String>) -> Binding<Date> {
        Binding(get: {
            let minutes = ModeAutomation.Block.minutes(block[keyPath: path]) ?? 0
            return Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var b = block
            b[keyPath: path] = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            change(b)
        })
    }
}

// MARK: - Building modes with AI

struct DescribeDayCard: View {
    @Environment(PetalApp.self) private var app
    @State private var describing = false

    var body: some View {
        if let provider = app.chatProvider {
            Card(footer: "Say what you do on this Mac, and \(provider.name) makes modes for it from your apps. You see each change in the chat.") {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(SettingsSection.claude.tint)
                    Text("Start from what you do").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Build my modes with AI…") { describing = true }.buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $describing) { DescribeDaySheet().environment(app) }
        }
    }
}

struct DescribeDaySheet: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you do on this Mac?").font(.system(size: 18, weight: .semibold))
            TextField("I code, write papers and talk to friends", text: $text, axis: .vertical).lineLimit(2...4)
            Text("\(app.chatProvider?.name ?? "The AI") builds a few modes from the apps you have, in place of the starter modes you haven't changed.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Build my modes") { app.describeDay(text); dismiss() }
                    .buttonStyle(.glassProminent).tint(SettingsSection.claude.tint).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Suggestions and history

/// What Petal would suggest now, to take or leave here as on the cards.
struct SuggestionsCard: View {
    @Environment(PetalApp.self) private var app
    @State private var suggestions: [Insights.Suggestion] = []
    @State private var working: String?

    var body: some View {
        if app.config.bool("activityLog") && app.config.bool("suggestModes") && !suggestions.isEmpty {
            Card(title: "Suggested for you", footer: "From which apps you use, and when. It stays on this Mac.") {
                ForEach(suggestions) { suggestion in
                    let mode = app.config.modes.first { $0.id == suggestion.mode }
                    HStack(spacing: 10) {
                        AppIcons(ids: suggestion.apps, size: 24)
                        Text(suggestion.text(modeName: mode?.name ?? suggestion.mode)).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if working == suggestion.key { ProgressView().controlSize(.small) }
                        Button("Not now") { Insights.dismiss(suggestion.key); load() }.buttonStyle(.glass).controlSize(.small)
                        Button(suggestion.kind == .mode ? "Make it" : "Keep it") {
                            working = suggestion.key
                            app.insights.accept(suggestion) { _ in working = nil; load() }
                        }
                        .buttonStyle(.glassProminent).tint(Color(nsColor: mode?.color ?? app.accent)).controlSize(.small)
                        .disabled(working != nil)
                    }
                }
            }
        }
        Color.clear.frame(height: 0).task { load() }
    }

    private func load() {
        Task { suggestions = await Task.detached { Array(Insights.suggestions().prefix(4)) }.value }
    }
}

struct HistoryCard: View {
    @Environment(PetalApp.self) private var app
    @State private var summary: Insights.Summary?
    @State private var forgetting = false

    var body: some View {
        Card(title: "Your history", footer: "Petal notes which app is in front, once a minute while you use your Mac: never window titles, sites or files. It stays on this Mac for 30 days.") {
            SettingToggle(key: "activityLog", title: "Keep a private history")
            if app.config.bool("activityLog") {
                SettingToggle(key: "suggestModes", title: "Suggest modes", detail: "At most one card a day, like “You often use Figma and Linear together”.")
                SettingToggle(key: "summary", title: "Weekly summary", detail: "On Monday morning: time in each mode last week.")
                if let summary {
                    SummaryRows(summary: summary).padding(12).background(.black.opacity(0.1), in: .rect(cornerRadius: 12))
                }
                HStack {
                    Button(summary == nil ? "Show the last 7 days" : "Hide") {
                        if summary != nil { summary = nil; return }
                        Task { summary = await Task.detached { Insights.summary(lastWeek: false) }.value }
                    }
                    .buttonStyle(.glass)
                    Button("Forget history…") { forgetting = true }.buttonStyle(.glass)
                }
            }
        }
        .confirmationDialog("Forget your history?", isPresented: $forgetting) {
            Button("Forget", role: .destructive) { app.activity.forget(); summary = nil }
        } message: {
            Text("Suggestions and summaries start over.")
        }
    }
}

// MARK: - A mode's Shortcut

struct ShortcutPicker: View {
    @Binding var name: String
    @State private var shortcuts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Run a Shortcut")
                Spacer()
                Picker("", selection: $name) {
                    Text("None").tag("")
                    if !name.isEmpty && !shortcuts.contains(name) { Text(name).tag(name) }
                    ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            Text("When a Desktop enters this mode, like one that turns on a Focus.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task { shortcuts = await Shortcuts.list() }
    }
}
