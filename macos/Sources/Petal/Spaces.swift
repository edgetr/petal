import AppKit
import ColorSync

/// Which Desktop each screen shows, numbered the way Mission Control and the "Switch to Desktop N" shortcuts
/// number them: 1, 2, 3… across every display. Full-screen apps are Spaces too, but no Desktop, so they get no number.
///
/// macOS says when the Space changes (NSWorkspace.activeSpaceDidChangeNotification) but has no public way to say
/// which one it is. SkyLight, the private framework behind Mission Control, answers that read-only, as yabai and
/// AeroSpace read it. It is looked up at run time, so a macOS that drops it leaves Petal on the default mode
/// instead of failing to launch.
@MainActor
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnection: MainConnection? = symbol("SLSMainConnectionID")
    private static let copySpaces: CopyManagedDisplaySpaces? = symbol("SLSCopyManagedDisplaySpaces")

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The Desktop number showing on `screen`, or nil on a full-screen app's Space or when it can't be told.
    static func desktop(on screen: NSScreen) -> Int? { showing(on: screen).desktop }

    /// What `screen` shows: a Desktop (its number), or a full-screen app's Space.
    static func showing(on screen: NSScreen) -> (desktop: Int?, fullScreen: Bool) {
        guard let mainConnection, let copySpaces,
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return (nil, false) }
        let wanted = uuid(of: screen)
        var number = 0
        var found: Int?
        var fullScreen = false
        for display in displays {
            let identifier = display["Display Identifier"] as? String ?? ""
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            // With "Displays have separate Spaces" off there is one entry, "Main", for every screen.
            let isThisScreen = identifier == "Main" || identifier.caseInsensitiveCompare(wanted ?? "") == .orderedSame
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                let here = isThisScreen && space["ManagedSpaceID"] as? Int == current
                guard space["type"] as? Int == 0 else {   // 0 is a Desktop; 4 a full-screen app
                    if here && space["type"] as? Int == 4 { fullScreen = true }
                    continue
                }
                number += 1
                if here { found = number }
            }
        }
        return (found, fullScreen)
    }

    /// How many Desktops there are, across every display.
    static func count() -> Int {
        guard let mainConnection, let copySpaces,
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return 0 }
        return displays.reduce(0) { $0 + ($1["Spaces"] as? [[String: Any]] ?? []).filter { $0["type"] as? Int == 0 }.count }
    }

    private static func uuid(of screen: NSScreen) -> String? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
