import Foundation

/// The dock's own decisions about a click, as rules without AppKit (checked by checks/DockRulesCheck.swift).
enum DockRules {
    /// One of the clicked app's windows, as the click weighs it: `rank` 0 on this Desktop's screen, 1 minimized,
    /// 2 anywhere else; `number` the window server's number for it (it stays with the window while it lives), when
    /// known; `title` its title.
    struct Window: Equatable {
        var rank: Int
        var number: UInt32?
        var title: String
        var minimized = false
    }

    /// Which window a click on an app's icon brings forward, from its windows front to back as the app lists them.
    /// The app not in front (`active` false): its frontmost window on this Desktop, else a minimized one, else the
    /// rest. The app in front: the one after the window in front (`focused`, known by its number, else by its title)
    /// in an order that doesn't change as windows come forward (by rank, then number), so clicking again goes
    /// through every window and back to the first. Nil when it has none.
    static func pick(_ windows: [Window], active: Bool, focused: UInt32?, focusedTitle: String) -> Int? {
        let front = windows.indices.sorted { (windows[$0].rank, $0) < (windows[$1].rank, $1) }
        guard active, !windows.isEmpty else { return front.first }
        let around = windows.indices.sorted { (windows[$0].rank, windows[$0].number ?? .max, $0) < (windows[$1].rank, windows[$1].number ?? .max, $1) }
        let inFront = around.firstIndex { index in
            let window = windows[index]
            guard !window.minimized else { return false }
            if let focused, let number = window.number { return number == focused }
            return window.title == focusedTitle
        }
        guard let inFront else { return front.first }
        return around[(inFront + 1) % around.count]
    }
}
