import AppKit
import SwiftUI

// The Dock page's windows and keyboard shortcuts groups.

/// A key combination, drawn as a key: clear glass of its own on the glass it sits on.
struct KeyCaps: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: TextSize.small, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .glassEffect(.clear, in: .rect(cornerRadius: Radius.chip))
    }
}

/// A row of a legend: the keys in one column, then what they do, and whether another app already has them.
struct KeyRow: View {
    let keys: String
    let what: String
    var taken = false
    /// The keys' column, so every row's words start on one line.
    var column: CGFloat = 112

    var body: some View {
        HStack(spacing: 10) {
            KeyCaps(text: keys).frame(width: column, alignment: .leading)
            Text(what).font(.system(size: TextSize.body))
            Spacer(minLength: 8)
            if taken { Text("Another app uses these keys").font(.system(size: TextSize.small)).foregroundStyle(.secondary) }
        }
    }
}

extension SettingsList {
    private static let tilingOn: (PetalApp) -> Bool = { $0.config.bool("tiling") }

    /// Tiling: its switch, and while it's on its gaps and its keys.
    static let windows = SettingsBlock("Windows", footer: "Turning it off leaves every window where it is.", [
        SettingsEntry(SettingToggle(key: "tiling", title: "Tile windows", detail: "Windows sit side by side and fill the screen."),
                      words: "tiling window manager layout"),
        SettingsEntry(SettingSlider(key: "tilingGaps", title: "Gaps", range: 0...32), words: "space between tiling", when: tilingOn),
        SettingsEntry("tilingKeys", "Tiling keys", words: "keyboard shortcuts swap float even", when: tilingOn) { _ in TilingKeys() },
    ])

    /// Petal's own keyboard shortcuts: their switch, and while it's on, which keys do what.
    static let shortcuts = SettingsBlock("Shortcuts", [
        SettingsEntry(SettingToggle(key: "shortcuts", title: "Keyboard shortcuts"), words: "hotkeys keys"),
        SettingsEntry("shortcutKeys", "Shortcut keys", words: "keyboard open petal ai add apps new note", when: { $0.config.bool("shortcuts") }) { _ in
            ShortcutKeys()
        },
    ])
}

/// Tiling's keys, and the one thing it does with the pointer.
struct TilingKeys: View {
    var body: some View {
        ForEach(Tiling.legend, id: \.keys) { row in
            KeyRow(keys: row.keys, what: row.what, taken: row.ids.allSatisfy(Tiling.taken.contains) && !row.ids.isEmpty)
        }
        KeyRow(keys: "Drag", what: "A window onto another swaps them")
    }
}

/// Petal's shortcuts, each with what it does.
struct ShortcutKeys: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        ForEach(app.hotkeys.keys) { key in
            KeyRow(keys: key.label, what: what(key), taken: app.hotkeys.taken.contains(key.id))
        }
    }

    private func what(_ key: Hotkeys.Key) -> String {
        switch key.id {
        case Hotkeys.ask: "Open Petal AI"
        case Hotkeys.search: "Add apps to the dock"
        case Hotkeys.note: "A new note on what’s in front"
        default: ""
        }
    }
}
