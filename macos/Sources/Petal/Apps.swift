import AppKit

/// An installed app.
struct InstalledApp: Identifiable, Hashable {
    let id: String   // bundle identifier
    let name: String
    let url: URL
}

/// Installed apps by bundle id, their names and icons, and the "+" search: the macOS side of AppSearch.qml and of
/// Omarchy's desktop entries.
@MainActor
enum Apps {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]
    private static var cachedList: [InstalledApp]?
    private static var listedAt = Date.distantPast

    private static var urls: [String: URL?] = [:]
    private static var urlsAt = Date()
    private static var recents: [String: [URL]] = [:]
    private static var fetching: Set<String> = []

    /// Where an app is installed, asked of Launch Services at most once a minute per app.
    /// Where an app is, as Launch Services says. Kept, and looked up again once a minute off the main thread (an app
    /// moved, installed or removed), so the dock never waits on Launch Services while it draws.
    static func url(_ id: String) -> URL? {
        if Date().timeIntervalSince(urlsAt) > 60 { recheckURLs() }
        if let known = urls[id] { return known }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        urls[id] = found
        return found
    }

    private static func recheckURLs() {
        urlsAt = Date()
        let ids = Array(urls.keys)
        DispatchQueue.global(qos: .utility).async {
            var fresh: [String: URL?] = [:]
            for id in ids { fresh[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (id, url) in fresh where urls[id] != url { urls[id] = url }
                }
            }
        }
    }

    /// Something the dock can show: an installed app, or a website shortcut.
    static func shows(_ id: String) -> Bool { Sites.isWeb(id) || url(id) != nil }

    /// An app's recent files as last looked up; hovering an app looks them up again, off the main thread.
    static func recent(_ id: String) -> [URL] { recents[id] ?? [] }

    static func prefetchRecent(_ id: String) {
        guard !fetching.contains(id) else { return }
        fetching.insert(id)
        let appURL = url(id)
        DispatchQueue.global(qos: .utility).async {
            let found = recentFiles(appURL: appURL, limit: 6)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    recents[id] = found
                    fetching.remove(id)
                }
            }
        }
    }

    static func name(_ id: String) -> String {
        if Sites.isWeb(id) { return Sites.domain(id) ?? id }   // a website shortcut is called by its site
        if let name = names[id] { return name }
        guard let url = url(id) else { return id }
        let bundle = Bundle(url: url)
        let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        names[id] = name
        return name
    }

    static func icon(_ id: String) -> NSImage {
        if Sites.isWeb(id) { return Sites.shared.tile(id) }
        if let icon = icons[id] { return icon }
        let icon = url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        icons[id] = icon
        return icon
    }

    static func icon(file url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// The icon if it's been read already (never touches the disk).
    static func cachedIcon(_ id: String) -> NSImage? { icons[id] }

    /// Reads an app's icon off the main thread, kept for next time (a plain one for an app that's gone).
    static func loadIcon(_ id: String, _ done: @escaping @MainActor (NSImage) -> Void) {
        if let icon = icons[id] { return done(icon) }
        DispatchQueue.global(qos: .utility).async {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if icons[id] == nil { icons[id] = icon }
                    done(icons[id] ?? icon)
                }
            }
        }
    }

    /// Every app in the usual places. Read once (ahead of time, by `warm`), then again off the main thread at most
    /// once a minute, so the "+" search never waits for the disk.
    static func installed() -> [InstalledApp] {
        if cachedList == nil { adopt(scan()) }
        if Date().timeIntervalSince(listedAt) > 60 && !scanning {
            scanning = true
            listedAt = Date()
            DispatchQueue.global(qos: .utility).async {
                let fresh = scan()
                DispatchQueue.main.async { MainActor.assumeIsolated { adopt(fresh); scanning = false } }
            }
        }
        return cachedList ?? []
    }
    private static var scanning = false

    private static func adopt(_ list: [InstalledApp]) {
        for app in list where names[app.id] == nil { names[app.id] = app.name }
        for app in list where urls[app.id] == nil { urls[app.id] = app.url }
        if list != cachedList { cachedList = list }
        listedAt = Date()
    }

    nonisolated private static func scan() -> [InstalledApp] {
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications", "/Applications/Utilities"]
        var seen = Set<String>()
        var list: [InstalledApp] = []
        for root in roots {
            let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                if enumerator?.level ?? 0 > 2 { enumerator?.skipDescendants(); continue }
                guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
                list.append(InstalledApp(id: id, name: name, url: url))
            }
        }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return list
    }

    /// At launch, off the main thread: the installed apps and their icons, so the first "+" search opens at once.
    static func warm() {
        DispatchQueue.global(qos: .utility).async {
            let list = scan()
            let pictures = list.map { ($0.id, NSWorkspace.shared.icon(forFile: $0.url.path)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    adopt(list)
                    for (id, icon) in pictures where icons[id] == nil { icons[id] = icon }
                }
            }
        }
    }

    /// Apps whose name starts with, then contains, the query.
    static func search(_ query: String) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return installed() }
        let all = installed()
        var starts: [InstalledApp] = []
        var contains: [InstalledApp] = []
        for app in all {
            guard let found = app.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            if found.lowerBound == app.name.startIndex { starts.append(app) } else { contains.append(app) }
        }
        return starts + contains
    }

    /// Files people opened lately that this app can open, newest first (macOS keeps no public per-app list).
    nonisolated static func recentFiles(appURL: URL?, limit: Int = 8) -> [URL] {
        guard let url = appURL, let types = Bundle(url: url)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        let utis = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }).filter { $0 != "public.data" && $0 != "public.item" }
        guard !utis.isEmpty else { return [] }
        let predicate = utis.map { "kMDItemContentTypeTree == '\($0)'" }.joined(separator: " || ")
        guard let query = MDQueryCreate(nil, "(\(predicate)) && kMDItemLastUsedDate >= $time.today(-30)" as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(query, 200)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var found: [(URL, Date)] = []
        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            found.append((URL(fileURLWithPath: path), used))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
