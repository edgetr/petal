import AppKit
import ApplicationServices

/// An app's window, as Accessibility sees it.
struct AppWindow: Identifiable, Equatable {
    let id: String          // pid and position in the app's window list, stable while the window stays
    let pid: pid_t
    let title: String
    let minimized: Bool
    let frame: CGRect       // top-left origin, as Accessibility and the window server count
    let element: AXUIElement

    static func == (a: AppWindow, b: AppWindow) -> Bool {
        a.id == b.id && a.title == b.title && a.minimized == b.minimized && a.frame == b.frame
    }
}

/// Windows through macOS's Accessibility API: which windows an app has, which are minimized, the title of the
/// window in front, and bringing one particular window forward. macOS asks the person once for permission
/// (System Settings > Privacy & Security > Accessibility); until then these answer empty and the dock still works.
@MainActor
enum Windows {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Every Accessibility call gives up after 0.3 s, so a hung app can't hang the dock. Called once at start.
    static func limitWaiting() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }

    /// Brings an app forward. Petal's dock never becomes the active app, and macOS lets only the active app hand
    /// activation on, so this goes through Launch Services, which may always do it.
    static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { app.activate(); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Shows macOS's own prompt, once, pointing at the Accessibility list.
    static func askForPermission() {
        let key = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt, which Swift 6 calls unsafe to share
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func windows(of pid: pid_t) -> [AppWindow] {
        guard trusted else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // a hung app mustn't hang the dock
        guard let list: [AXUIElement] = value(app, kAXWindowsAttribute) else { return [] }
        var result: [AppWindow] = []
        for (index, window) in list.enumerated() {
            guard let role: String = value(window, kAXSubroleAttribute), role == kAXStandardWindowSubrole as String else { continue }
            let title: String = value(window, kAXTitleAttribute) ?? ""
            let minimized: Bool = value(window, kAXMinimizedAttribute) ?? false
            var frame = CGRect.zero
            if let position: AXValue = value(window, kAXPositionAttribute), let size: AXValue = value(window, kAXSizeAttribute) {
                var point = CGPoint.zero, extent = CGSize.zero
                AXValueGetValue(position, .cgPoint, &point)
                AXValueGetValue(size, .cgSize, &extent)
                frame = CGRect(origin: point, size: extent)
            }
            result.append(AppWindow(id: "\(pid)-\(index)", pid: pid, title: title, minimized: minimized,
                                    frame: frame, element: window))
        }
        return result
    }

    /// Brings one window forward: unminimizes it, raises it, and makes its app the active one. The pointer stays.
    static func focus(_ window: AppWindow) {
        if window.minimized { AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: window.pid) { bringForward(app) }
    }

    /// Moves and resizes a window (top-left origin).
    static func setFrame(_ window: AppWindow, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        if frame.origin != window.frame.origin, let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
        }
        if frame.size != window.frame.size, let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value)
        }
    }

    static func minimize(_ window: AppWindow) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    static func close(_ window: AppWindow) {
        guard let button: AXUIElement = value(window.element, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    /// The title of the front window of the app in front: a browser's is its tab's title.
    static func frontTitle() -> String {
        guard trusted, let app = NSWorkspace.shared.frontmostApplication else { return "" }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let window: AXUIElement = value(element, kAXFocusedWindowAttribute) else { return "" }
        return value(window, kAXTitleAttribute) ?? ""
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        return raw as? T
    }
}
