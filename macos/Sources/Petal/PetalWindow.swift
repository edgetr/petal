import AppKit

/// Bringing one of Petal's own windows to the front (settings, the welcome, What's New, a shared dock).
@MainActor
enum PetalWindow {
    /// Petal is a background app, so it has to ask to come forward. Asked from the menu bar's menu, the menu is still
    /// closing when the item's action runs, and macOS turns the request down then: the window opened behind the app
    /// in front, and a second click was needed. So it's asked once the menu has gone (the next turn of the main
    /// loop), and the window is ordered over the others even if macOS keeps another app active.
    static func bringForward(_ window: NSWindow) {
        DispatchQueue.main.async {
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
