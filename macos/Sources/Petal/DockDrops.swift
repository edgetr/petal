import AppKit

/// Things dragged onto the dock: an app, a folder or a web address is added to it (a folder as a stack, an address
/// as a website shortcut); documents dropped on an app are opened with it. An app is never opened "with" another
/// app. The rules are `DockRules.dropped` and `DockRules.drop`.
@MainActor
enum DockDrops {
    /// What the dock's drop targets take.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL]

    /// What a drag holds, as the dock weighs it.
    static func items(_ urls: [URL]) -> [DockRules.Dropped] {
        urls.compactMap { url in
            if url.isFileURL {
                let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return DockRules.dropped(path: url.path, web: nil, isDirectory: directory == true)
            }
            return Sites.address(url.absoluteString).flatMap { DockRules.dropped(path: nil, web: $0, isDirectory: false) }
        }
    }

    static func items(_ pasteboard: NSPasteboard) -> [DockRules.Dropped] {
        items(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
    }

    /// What dropping these would do on the app `onApp` (nil: the dock's glass or "+").
    static func action(_ items: [DockRules.Dropped], onApp: String?) -> DockRules.DropAction? {
        DockRules.drop(items, onApp: onApp.map { !Sites.isWeb($0) } ?? false)
    }

    /// Does it: adds what's added, or opens the documents with the app.
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

    private static func add(_ items: [DockRules.Dropped]) {
        let config = PetalApp.shared.config
        var folders = config.strings("stackFolders")
        let home = NSHomeDirectory()
        for item in items {
            switch item {
            case .app(let path):
                if let id = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier { config.addApp(id) }
            case .site(let address):
                config.addApp(address)
            case .folder(let path):
                let short = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
                let shown = Stacks.resolve(folders)
                if !folders.contains(short) && !shown.contains(short) { folders.append(short) }
            case .document:
                break
            }
        }
        if folders != config.strings("stackFolders") {
            config.set("stackFolders", folders)
            if !config.bool("stacks") { config.set("stacks", true) }   // a folder dropped on the dock is meant to show
        }
    }
}
