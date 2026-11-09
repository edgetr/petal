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

    /// When the newest file arrived in a folder (nil: it's empty or can't be read). Reads the disk: never on the
    /// dock's thread.
    static func newest(_ folder: String) -> Date? {
        entries(folder, limit: 1).first?.added
    }

    static var trash: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash") }
    static let trashFolder = "~/.Trash"

    /// Whether the Trash is empty, nil when Petal can't tell. Reads the disk or asks Finder: never on the dock's thread.
    /// macOS shows the Trash's contents only to apps with Full Disk Access; without it, Finder answers, once the
    /// person has let Petal use Finder (opening or emptying the Trash from the dock asks). Petal never asks just for this.
    static func trashIsEmpty() -> Bool? {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
            return names.allSatisfy { $0.hasPrefix(".") }
        }
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let target = finder.aeDesc,
              AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false) == noErr else { return nil }
        var error: NSDictionary?
        guard let count = NSAppleScript(source: "tell application \"Finder\" to return count of items of trash")?
            .executeAndReturnError(&error), error == nil else { return nil }
        return count.int32Value == 0
    }

    static func moveToTrash(_ urls: [URL]) {
        for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        Task { @MainActor in PetalApp.shared.signals.lookAtTrash() }
    }

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "heic", "tiff"]

    static func isImage(_ url: URL) -> Bool { imageTypes.contains(url.pathExtension.lowercased()) }

    /// Finder answers Apple events in its own time, so they're sent off the main thread.
    private static let finder = DispatchQueue(label: "petal.finder")

    /// Opens the Trash in Finder, as macOS's Dock does: Launch Services hands Finder the Trash folder, and Finder
    /// comes forward with that window, nothing else moving. (Telling Finder to `activate` through AppleScript could
    /// bring it forward before its Trash window was open, with only the desktop in front, which macOS takes for a
    /// click on the wallpaper when "Click wallpaper to reveal desktop" is on: every window slid away.)
    static func openTrash() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open(trash, configuration: configuration)
        // Without Full Disk Access, Finder is how Petal tells whether the Trash is empty: asked once here (macOS asks
        // the person the first time), so the dock's Trash can show it. Asking Finder this brings nothing forward.
        finder.async {
            if (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) == nil {
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to return count of items of trash")?.executeAndReturnError(&error)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { PetalApp.shared.signals.lookAtTrash() } }
        }
    }

    static func emptyTrash() {
        finder.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            DispatchQueue.main.async { MainActor.assumeIsolated { PetalApp.shared.signals.lookAtTrash() } }
        }
    }
}

/// Watches folders through the kernel (a vnode source on each), and reads them on its own queue, never on the
/// dock's thread. `changed` runs on that queue, once at the start and shortly after each change, with whether the
/// kernel is watching the folder (when it can't, the caller looks now and then instead).
final class FolderWatcher: @unchecked Sendable {
    let queue: DispatchQueue
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private let changed: (String, Bool) -> Void

    init(_ label: String, changed: @escaping (String, Bool) -> Void) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.changed = changed
    }

    /// Watches exactly these folders (paths with ~), each read once now.
    func watch(_ folders: [String]) {
        queue.async { [self] in
            for (folder, source) in sources where !folders.contains(folder) {
                source.cancel()
                sources[folder] = nil
            }
            for folder in folders where sources[folder] == nil {
                let fd = open(Stacks.url(folder).path, O_EVTONLY)
                if fd >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename, .delete],
                                                                           queue: queue)
                    source.setEventHandler { [weak self] in self?.soon(folder) }
                    source.setCancelHandler { close(fd) }
                    source.resume()
                    sources[folder] = source
                }
                changed(folder, sources[folder] != nil)
            }
        }
    }

    /// Reads a folder again now.
    func look(_ folder: String) {
        queue.async { [self] in changed(folder, sources[folder] != nil) }
    }

    /// A download or a copy changes a folder many times a second: it's read once things settle.
    private func soon(_ folder: String) {
        pending[folder]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changed(folder, self.sources[folder] != nil)
        }
        pending[folder] = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// What an open stack shows, read off the main thread: the panel opens once it's known, and follows the folder.
@MainActor @Observable
final class StackContents {
    let folder: String
    private(set) var entries: [Stacks.Entry] = []
    @ObservationIgnored private var asked = 0
    private static let queue = DispatchQueue(label: "petal.stack", qos: .userInitiated)

    init(folder: String, entries: [Stacks.Entry] = []) {
        self.folder = folder
        self.entries = entries
    }

    func load(_ done: @escaping () -> Void = {}) {
        asked += 1
        let ask = asked, folder = folder
        Self.queue.async {
            let found = Stacks.entries(folder, limit: 12)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ask == self.asked else { return }
                    if found != self.entries { self.entries = found }
                    done()
                }
            }
        }
    }
}

/// Stills of windows for previews, taken with ScreenCaptureKit. macOS asks the person once (Screen Recording); until then the
/// preview shows the windows' titles only.
enum Capture {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    static func askForPermission() { CGRequestScreenCaptureAccess() }

    /// One picture per window, matched to Accessibility's windows by their window server id, else by app and frame.
    static func capture(_ windows: [(window: AppWindow, number: CGWindowID?)], height: CGFloat = 150) async -> [String: NSImage] {
        guard allowed, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [:] }
        var result: [String: NSImage] = [:]
        // Other apps' windows only: never one of Petal's own (a note's paper, its fan, the Petal Notes window).
        let me = ProcessInfo.processInfo.processIdentifier
        let others = content.windows.filter { $0.owningApplication?.processID != me }
        for (window, number) in windows {
            let byNumber = number.flatMap { number in others.first { $0.windowID == number } }
            guard let match = byNumber ?? others.first(where: {
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
