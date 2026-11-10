import AppKit
import SwiftUI

// The settings window's keyboard shortcuts card.

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
            Text("Add apps to the dock").font(.system(size: 12))
        case Hotkeys.note:
            Text("A new note on what’s in front").font(.system(size: 12))
        default:
            EmptyView()
        }
    }
}
