import AppKit
import ApplicationServices
import ScreenCaptureKit

/// `Petal --display-check <folder>`: the one check that makes a real hidden display (RunDisplay.swift), for whoever
/// is at the Mac to run on purpose. It changes the screens' arrangement for a few seconds: never run by a check, a
/// bench, a snapshot or an agent working alone.
///
/// It makes one display, places it at a corner of the person's screens, opens a throwaway text file in TextEdit
/// without activating it, moves that window onto the display and sets its text, all through Accessibility alone (no
/// AppleScript, no System Events), writes a PNG of the display into the folder, shows that the app and window the
/// person had in front, their pointer and their screens didn't change, then closes the window and removes the
/// display. One line per step, "ok" or "FAIL" with what was read, so a failure says exactly what went wrong; the
/// exit code is the number of failures (0: all passed).
@MainActor
enum DisplayCheck {
    private static var failures = 0
    private static var passes = 0

    private static func step(_ ok: Bool, _ what: String, _ detail: String = "") {
        print((ok ? "ok    " : "FAIL  ") + what + (detail.isEmpty ? "" : "  [" + detail + "]"))
        if ok { passes += 1 } else { failures += 1 }
    }

    private static func say(_ text: String) { print("      " + text) }

    @discardableResult
    private static func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return done()
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }

    /// The app in front and its focused window's number, as the person has them.
    private static func front() -> (pid: pid_t, name: String, window: CGWindowID?) {
        let running = NSWorkspace.shared.frontmostApplication
        let pid = running?.processIdentifier ?? 0
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let window: AXUIElement? = Windows.value(app, kAXFocusedWindowAttribute)
        return (pid, running?.localizedName ?? "nothing", window.flatMap { Windows.id(of: $0) })
    }

    /// The first text area in a window, a few levels down.
    private static func textArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if (Windows.value(element, kAXRoleAttribute) as String?) == (kAXTextAreaRole as String) { return element }
        guard depth < 8 else { return nil }
        let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
        for child in children {
            if let found = textArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    static func run(folder path: String) -> Never {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        print("Petal display check, macOS \(version). This makes a real display for a few seconds.")

        // 1. What it needs.
        step(VirtualDisplay.available, "macOS has the classes Petal makes a display with",
             VirtualDisplay.available ? "" : "missing: " + VirtualDisplay.missing.joined(separator: ", "))
        let trusted = AXIsProcessTrusted()
        step(trusted, "this Petal may use Accessibility", trusted ? "" : "allow it for the program this was started from (System Settings, Privacy & Security, Accessibility)")
        let recording = CGPreflightScreenCaptureAccess()
        step(recording, "this Petal may record the screen (for the picture)", recording ? "" : "without Screen Recording there is no PNG; the rest still runs")
        guard VirtualDisplay.available else { finish() }

        // 2. How things are before.
        let before = front()
        let screensBefore = Screens.displays.map { CGDisplayBounds($0) }
        let pointerBefore = NSEvent.mouseLocation
        let countBefore = NSScreen.screens.count
        say("in front before: \(before.name) (pid \(before.pid), window \(before.window.map(String.init) ?? "none"))")
        say("the person's screens before: " + screensBefore.map(describe).joined(separator: " | "))

        // 3. The display.
        let gone = GoneFlag()
        let display = VirtualDisplay.make(name: "Petal display check", serial: UInt32(getpid()), points: RunDisplayRules.size) { gone.set() }
        step(display != nil, "a display was made", display.map { "id \($0.id), \($0.hiDPI ? "2880×1800 pixels (HiDPI)" : "1440×900 pixels (HiDPI refused)")" }
            ?? "CGVirtualDisplay refused: initWithDescriptor or applySettings failed")
        guard let display else { finish() }
        let id = display.id

        // 4. Where it is.
        let placed = PlacedBox()
        RunDisplays.queue.async {
            let placing = RunDisplays.place(id, size: RunDisplayRules.size)
            DispatchQueue.main.async { placed.value = placing }
        }
        wait(15) { placed.value != nil }
        for line in placed.value?.tried ?? ["placing never answered"] { say(line) }
        let frame = placed.value?.frame
        step(frame != nil, "it touches the person's screens only at a corner (the pointer can't reach it)", frame.map(describe) ?? "see the tries above")
        let online = CGDisplayIsOnline(id) != 0
        step(online, "macOS lists it as a display", "CGDisplayIsOnline \(online), bounds \(describe(CGDisplayBounds(id)))")
        wait(1.5) { NSScreen.screens.count > countBefore }
        step(NSScreen.screens.count == countBefore + 1, "AppKit sees one more screen", "\(countBefore) before, \(NSScreen.screens.count) now")
        step(Screens.all.count == countBefore, "Petal's own list of the person's screens leaves it out", "\(Screens.all.count) of \(NSScreen.screens.count)")
        let screensDuring = Screens.displays.map { CGDisplayBounds($0) }
        step(screensDuring == screensBefore, "the person's screens didn't move or change size",
             screensDuring == screensBefore ? "" : "now " + screensDuring.map(describe).joined(separator: " | "))

        // 5. A TextEdit window of the check's own: a throwaway file, opened without activating anything.
        var window: (window: CGWindowID, pid: pid_t, element: AXUIElement)?
        let file = folder.appending(path: "petal-display-check-\(getpid()).txt")
        let target = frame ?? CGDisplayBounds(id)
        if trusted {
            try? Data("Petal display check\n".utf8).write(to: file)
            let bundle = "com.apple.TextEdit"
            let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            step(textEdit != nil, "TextEdit is installed")
            if let textEdit {
                let existing = Set(RunDisplays.windowNumbers(bundle: bundle).keys)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                let opened = OpenFlag()
                NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: configuration) { _, error in
                    opened.error = error?.localizedDescription
                    opened.set()
                }
                wait(20) { opened.isSet }
                step(opened.isSet && opened.error == nil, "TextEdit opened the throwaway file without being activated", opened.error ?? (opened.isSet ? "" : "Launch Services never answered"))
                let found = FoundBox()
                RunDisplays.queue.async {
                    let made = RunDisplays.newWindows(bundle: bundle, before: existing, timeout: 15, live: { true })
                    DispatchQueue.main.async { found.value = made; found.done = true }
                }
                wait(20) { found.done }
                window = found.value.first
                step(window != nil, "its new window was found through Accessibility", window.map { "window \($0.window), pid \($0.pid)" }
                    ?? "no new standard window of TextEdit in 15 s (\(existing.count) were there before)")
            }
        } else {
            say("skipped: opening, moving and typing need Accessibility")
        }

        // 6. Onto the display, and its text set, through Accessibility alone.
        if let window {
            let was = Windows.frame(of: window.element)
            let moved = MovedBox()
            nonisolated(unsafe) let element = window.element
            let owner = window.pid
            RunDisplays.queue.async {
                let ok = RunDisplays.move(element, pid: owner, to: target, index: 0)
                DispatchQueue.main.async { moved.value = ok }
            }
            wait(6) { moved.value != nil }
            let now = Windows.frame(of: window.element)
            let server = RunDisplays.windowNumbers(pid: window.pid)[window.window]?.frame
            let there = server.map { target.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
            step(moved.value == true && there, "the window is on the display",
                 "was \(was.map(describe) ?? "?"), Accessibility says \(now.map(describe) ?? "?"), the window server says \(server.map(describe) ?? "?"), the display is \(describe(target))")
            let words = "Typed by Petal on a hidden display, \(Int(Date().timeIntervalSince1970))"
            if let area = textArea(in: window.element) {
                let set = AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, words as CFString)
                wait(0.4) { false }
                let read: String = Windows.value(area, kAXValueAttribute) ?? ""
                step(set == .success && read == words, "its text was set through Accessibility and reads back", "AXError \(set.rawValue), reads “\(read.prefix(60))”")
            } else {
                step(false, "its text was set through Accessibility and reads back", "no text area found in the window")
            }
        }

        // 7. The person's front app, window, pointer: as they were.
        let after = front()
        step(after.pid == before.pid, "the app in front didn't change", "before \(before.name) (\(before.pid)), now \(after.name) (\(after.pid))")
        step(after.window == before.window, "its window in front didn't change",
             "before \(before.window.map(String.init) ?? "none"), now \(after.window.map(String.init) ?? "none")")
        let pointerNow = NSEvent.mouseLocation
        let pointerOn = Screens.all.contains { $0.frame.contains(pointerNow) }
        say("pointer before \(Int(pointerBefore.x)),\(Int(pointerBefore.y)), now \(Int(pointerNow.x)),\(Int(pointerNow.y)) (it may have moved if someone moved it)")
        step(pointerOn, "the pointer is on one of the person's screens")

        // 8. A picture of the display.
        if recording {
            let shot = ShotBox()
            Task {
                shot.value = await picture(of: id)
                shot.done = true
            }
            wait(15) { shot.done }
            let png = folder.appending(path: "display.png")
            var written = false
            if let image = shot.value {
                let rep = NSBitmapImageRep(cgImage: image)
                written = (try? rep.representation(using: .png, properties: [:])?.write(to: png)) != nil
            }
            step(written, "a PNG of the display was written", written ? png.path : (shot.value == nil ? "ScreenCaptureKit gave no picture of display \(id)" : "couldn't write \(png.path)"))
        }

        // 9. The window closed (its file is a throwaway), or brought back if it wouldn't close.
        if let window {
            if let button: AXUIElement = Windows.value(window.element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            let closed = wait(3) { RunDisplays.windowNumbers(pid: window.pid)[window.window] == nil }
            if !closed {
                Windows.place(window.element, pid: window.pid, RunDisplayRules.frame(for: Windows.frame(of: window.element)?.size ?? .zero, on: RunDisplays.personArea()), size: false)
            }
            step(closed, "the window closed", closed ? "" : "it stayed open (it may be asking to save), so it was moved to your main screen: close it yourself")
        }
        try? fm.removeItem(at: file)

        // 10. The display removed.
        display.remove()
        let removed = wait(5) { CGDisplayIsOnline(id) == 0 }
        step(removed, "the display is gone", "CGDisplayIsOnline \(CGDisplayIsOnline(id) != 0)")
        wait(1.5) { NSScreen.screens.count == countBefore }
        Screens.forget(id)
        step(NSScreen.screens.count == countBefore, "AppKit sees the screens it saw before", "\(countBefore) before, \(NSScreen.screens.count) now")
        let screensAfter = Screens.displays.map { CGDisplayBounds($0) }
        step(screensAfter == screensBefore, "the person's screens are as they were",
             screensAfter == screensBefore ? "" : "now " + screensAfter.map(describe).joined(separator: " | "))
        let last = front()
        step(last.pid == before.pid && last.window == before.window, "the app and window in front are still the same",
             "now \(last.name) (\(last.pid)), window \(last.window.map(String.init) ?? "none")")
        step(!gone.isSet, "macOS never took the display away by itself while it was in use")
        finish()
    }

    private static func finish() -> Never {
        print("\(passes) passed, \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    /// The whole display as it is, with everything on it.
    nonisolated private static func picture(of id: CGDirectDisplayID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

private final class GoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
}

private final class OpenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var text: String?
    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
    var error: String? {
        get { lock.withLock { text } }
        set { lock.withLock { text = newValue } }
    }
}

private final class PlacedBox: @unchecked Sendable { var value: RunDisplays.Placing? }
private final class MovedBox: @unchecked Sendable { var value: Bool? }
private final class FoundBox: @unchecked Sendable {
    var value: [(window: CGWindowID, pid: pid_t, element: AXUIElement)] = []
    var done = false
}
private final class ShotBox: @unchecked Sendable {
    var value: CGImage?
    var done = false
}
