import AppKit
import ScreenCaptureKit

/// A folder stack: the folder's newest files, newest first, as macOS's Dock sorts a stack by date added.
enum Stacks {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let added: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    static func url(_ folder: String) -> URL { URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }

    static func name(_ folder: String) -> String { FileManager.default.displayName(atPath: url(folder).path) }

    static func entries(_ folder: String, limit: Int = 40) -> [Entry] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url(folder), includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        let entries = urls.compactMap { url -> Entry? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(url: url, added: values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast)
        }
        return Array(entries.sorted { $0.added > $1.added }.prefix(limit))
    }

    /// Where macOS saves screenshots: its own setting, else the Desktop.
    static var screenshotsFolder: String {
        let custom = (CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String)
            .map { ($0 as NSString).expandingTildeInPath }
        let path = custom ?? (NSHomeDirectory() + "/Desktop")
        return path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }

    /// Omarchy's default folders, translated: ~/Pictures/Screenshots is where macOS keeps screenshots instead.
    static func resolve(_ folders: [String]) -> [String] {
        folders.map { $0 == "~/Pictures/Screenshots" && !FileManager.default.fileExists(atPath: url($0).path) ? screenshotsFolder : $0 }
            .filter { FileManager.default.fileExists(atPath: url($0).path) }
    }

    static var trash: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash") }

    static var trashIsEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).filter { !$0.hasPrefix(".") }.isEmpty
    }

    static func moveToTrash(_ urls: [URL]) {
        for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "heic", "tiff"]

    static func isImage(_ url: URL) -> Bool { imageTypes.contains(url.pathExtension.lowercased()) }

    static func openTrash() {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\"\nopen trash\nactivate\nend tell")?.executeAndReturnError(&error)
    }

    static func emptyTrash() {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
    }
}

/// Stills of windows for previews, taken with ScreenCaptureKit. macOS asks the person once (Screen Recording); until then the
/// preview shows the windows' titles only.
enum Capture {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    static func askForPermission() { CGRequestScreenCaptureAccess() }

    /// One picture per window, matched to Accessibility's windows by app and frame.
    static func capture(_ windows: [AppWindow], height: CGFloat = 150) async -> [String: NSImage] {
        guard allowed, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [:] }
        var result: [String: NSImage] = [:]
        for window in windows {
            guard let match = content.windows.first(where: {
                $0.owningApplication?.processID == window.pid && $0.windowLayer == 0
                    && abs($0.frame.minX - window.frame.minX) < 4 && abs($0.frame.minY - window.frame.minY) < 4
                    && abs($0.frame.width - window.frame.width) < 4
            }) else { continue }
            let configuration = SCStreamConfiguration()
            let scale = height * 2 / max(1, match.frame.height)
            configuration.width = Int(match.frame.width * scale)
            configuration.height = Int(match.frame.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: match)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                result[window.id] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            }
        }
        return result
    }
}
