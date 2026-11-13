import AppKit

/// Things dragged onto the dock: an app, a folder or a web address is added to it (a folder as a stack, an address
/// as a website shortcut); documents dropped on an app are opened with it. An app is never opened "with" another
/// app. The rules are `DockRules.dropped` and `DockRules.drop`.
///
/// The dock's main thread never waits on the disk: while something is dragged over the dock it's weighed from what
/// its URLs say (a folder's URL ends in "/", an app's in ".app"); a file URL that doesn't say whether it's a folder is
/// looked at once, off the main thread, and the answer used from the next moment of the drag on. What needs the files
/// themselves (an app's bundle identifier, a folder really being one) is read off the main thread once it's dropped,
/// and the dock changes on the main thread after.
@MainActor
enum DockDrops {
    /// What the dock's drop targets take.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL]

    /// What a drag holds, as the dock weighs it, from its URLs alone.
    static func items(_ urls: [URL]) -> [DockRules.Dropped] {
        urls.compactMap { url in
            guard url.isFileURL else {
                return Sites.address(url.absoluteString).flatMap { DockRules.dropped(path: nil, web: $0, isDirectory: false) }
            }
            let path = url.path
            let folder = url.hasDirectoryPath || (folders[path] ?? false)
            if !url.hasDirectoryPath, !path.lowercased().hasSuffix(".app"), folders[path] == nil { lookAt(path) }
            return DockRules.dropped(path: path, web: nil, isDirectory: folder)
        }
    }

    /// The URLs of the drag under way, read from its pasteboard once per drag.
    static func urls(_ sender: NSDraggingInfo) -> [URL] {
        if let held, held.drag == sender.draggingSequenceNumber { return held.urls }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        held = (sender.draggingSequenceNumber, urls)
        return urls
    }
    private static var held: (drag: Int, urls: [URL])?

    static func items(_ sender: NSDraggingInfo) -> [DockRules.Dropped] { items(urls(sender)) }

    // MARK: A file URL that doesn't say it's a folder

    /// Whether a dragged path is a folder, as read off the main thread (absent: not read yet).
    private static var folders: [String: Bool] = [:]
    private static var looking: Set<String> = []
    nonisolated private static let disk = DispatchQueue(label: "petal.dock.drops", qos: .userInitiated)

    private static func lookAt(_ path: String) {
        guard !looking.contains(path) else { return }
        looking.insert(path)
        if folders.count > 200 { folders = [:] }   // a few drags' worth
        disk.async {
            var isDirectory: ObjCBool = false
            let folder = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    looking.remove(path)
                    folders[path] = folder
                }
            }
        }
    }

    // MARK: Dropping

    /// What dropping these would do on the app `onApp` (nil: the dock's glass or "+").
    static func action(_ items: [DockRules.Dropped], onApp: String?) -> DockRules.DropAction? {
        DockRules.drop(items, onApp: onApp.map { !Sites.isWeb($0) } ?? false)
    }

    /// Does it: adds what's added (read off the main thread first), or opens the documents with the app.
    @discardableResult
    static func perform(_ items: [DockRules.Dropped], onApp: String?) -> Bool {
        switch action(items, onApp: onApp) {
        case .add(let additions):
            add(additions)
            return true
        case .open(let paths):
            guard let onApp else { return false }
            PetalApp.shared.docks.launch(onApp, files: paths.map { URL(fileURLWithPath: $0) })
            return true
        case nil:
            return false
        }
    }

    /// Reads what the dock needs of each thing dropped off the main thread (an app's bundle identifier, whether a
    /// folder is one and which stacks the setting really shows), then changes the dock on the main thread.
    private static func add(_ items: [DockRules.Dropped]) {
        let stacks = PetalApp.shared.config.strings("stackFolders")
        let home = NSHomeDirectory()
        disk.async {
            var apps: [String] = []
            var newFolders: [String] = []
            let shown = Stacks.resolve(stacks)
            for item in items {
                switch item {
                case .app(let path):
                    if let id = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier { apps.append(id) }
                case .site(let address):
                    apps.append(address)
                case .folder(let path):
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                    let short = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
                    if !stacks.contains(short) && !shown.contains(short) && !newFolders.contains(short) { newFolders.append(short) }
                case .document:
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let config = PetalApp.shared.config
                    for id in apps { config.addApp(id) }
                    let folders = config.strings("stackFolders")
                    let more = newFolders.filter { !folders.contains($0) }
                    guard !more.isEmpty else { return }
                    config.set("stackFolders", folders + more)
                    if !config.bool("stacks") { config.set("stacks", true) }   // a folder dropped on the dock is meant to show
                }
            }
        }
    }
}
