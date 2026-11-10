import AppKit

/// The person's screens: every screen but a run's hidden display (RunDisplay.swift makes those). Everything Petal shows
/// the person (the dock, notes, edge tabs, the note pad, tooltips, cards, the pointer of their own acts) and everything
/// it takes for "the screen" or "in front" asks here, never `NSScreen.screens` or `NSScreen.main` itself. With no run
/// display (always, while `runDisplays` is off) these are exactly `NSScreen.screens` and `NSScreen.main`.
/// Foundation and AppKit only, in a file of its own: the pure checks compile sources that pick a screen.
enum Screens {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var runs: Set<CGDirectDisplayID> = []

    /// The displays that are a run's now (or were a moment ago, until macOS stops listing them).
    nonisolated static var runIDs: Set<CGDirectDisplayID> { lock.withLock { runs } }
    nonisolated static func isRun(_ id: CGDirectDisplayID) -> Bool { lock.withLock { runs.contains(id) } }

    /// A display is a run's from before it comes online (so nothing of Petal's ever takes it for a screen), until
    /// macOS no longer lists it (`forget`).
    nonisolated static func mark(_ id: CGDirectDisplayID) { lock.withLock { _ = runs.insert(id) } }

    /// The displays macOS has online now, from its own list. Never `CGDisplayIsOnline`: asked about the id of a
    /// display that's gone, it goes on saying yes (seen on macOS 27.3, twelve seconds after), while this list and the
    /// active one no longer hold it.
    nonisolated static var online: Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &list, &count)
        return Set(list.prefix(Int(count)))
    }

    nonisolated static func isOnline(_ id: CGDirectDisplayID) -> Bool { online.contains(id) }

    /// A removed display's id is let go only once it's really gone (out of macOS's list): between its removal and
    /// macOS saying so, it's still not the person's.
    nonisolated static func forget(_ id: CGDirectDisplayID) {
        guard !isOnline(id) else { return }
        lock.withLock { _ = runs.remove(id) }
    }

    private static func number(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static var all: [NSScreen] {
        let hidden = runIDs
        if hidden.isEmpty { return NSScreen.screens }
        let persons = NSScreen.screens.filter { screen in number(of: screen).map { !hidden.contains($0) } ?? true }
        // A Mac with no screen of the person's at all (lid shut, nothing plugged in): what there is, never none.
        return persons.isEmpty ? NSScreen.screens : persons
    }

    /// The screen with the keyboard, when it's the person's; else their first.
    static var main: NSScreen? {
        let hidden = runIDs
        if hidden.isEmpty { return NSScreen.main }
        if let main = NSScreen.main, number(of: main).map({ !hidden.contains($0) }) ?? true { return main }
        return all.first
    }

    /// The person's displays as the window server lists them (any thread).
    nonisolated static var displays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &list, &count)
        let hidden = runIDs
        return list.prefix(Int(count)).filter { !hidden.contains($0) }
    }

    /// The person's main display (the one with the menu bar; never a run's).
    nonisolated static var mainDisplay: CGDirectDisplayID {
        let main = CGMainDisplayID()
        return isRun(main) ? (displays.first ?? main) : main
    }

    /// The run displays' frames now, in the window server's coordinates (any thread).
    nonisolated static var runFrames: [(id: CGDirectDisplayID, frame: CGRect)] {
        let here = online
        return runIDs.compactMap { id in here.contains(id) ? (id, CGDisplayBounds(id)) : nil }
    }

    /// A window with this frame (the window server's coordinates) is on a run's display.
    nonisolated static func onRunDisplay(_ frame: CGRect) -> Bool {
        guard !runIDs.isEmpty else { return false }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        return runFrames.contains { $0.frame.contains(middle) }
    }
}
