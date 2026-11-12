import AppKit
import UniformTypeIdentifiers

/// A task a note holds (`task:`): its parts as chips, and Open all, which brings them back through the normal open
/// paths (a tab by its address, a file found by the one file resolver, a mail by its message address), never moving
/// the pointer. The one place that opens a task's parts, for the Petal Notes window and the note itself alike, and
/// that opens a link a helper left. Never an app or a script: a task's `url_or_path` (and a helper's link) can come
/// from sync or a tool. A file is resolved first (aliases and symbolic links, off the main thread) and opened only
/// when what it really is is a document and none of the kinds that run something or point elsewhere; anything else is
/// shown in Finder, never opened. Tabs open only for http and https; mail only by its message address.
enum NoteTasks {
    /// A part in a few words: a tab's site (or title), a file's name, "Mail · title", a window's title.
    static func chip(_ item: NoteContract.TaskItem) -> String {
        switch item.kind {
        case "tab":
            let host = NoteText.host(item.target)
            return host.isEmpty ? (item.title.isEmpty ? "A tab" : item.title) : host
        case "file": return item.target.isEmpty ? (item.title.isEmpty ? "A file" : item.title) : (item.target as NSString).lastPathComponent
        case "mail": return "Mail" + (item.title.isEmpty ? "" : " · " + item.title)
        default: return item.title.isEmpty ? "A window" : item.title
        }
    }

    /// An address a helper's link or a tab may open: http or https only.
    static func web(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Where a part opens: a tab only at a web address (http or https), a file only at an absolute path, a mail only
    /// by its message address (`message:`, or a Message-ID in angle brackets); a window has nothing to open (nil).
    static func url(_ item: NoteContract.TaskItem) -> URL? {
        let target = item.target.trimmingCharacters(in: .whitespaces)
        switch item.kind {
        case "tab":
            guard let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        case "file":
            if target.hasPrefix("file://") { return URL(string: target).flatMap { $0.isFileURL ? $0 : nil } }
            let path = (target as NSString).expandingTildeInPath
            return path.hasPrefix("/") && !path.contains("\0") ? URL(fileURLWithPath: path) : nil
        case "mail":
            if target.lowercased().hasPrefix("message:") { return URL(string: target) }
            guard target.hasPrefix("<"), target.hasSuffix(">"),
                  let id = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".@-_"))) else { return nil }
            return URL(string: "message://" + id)
        default:
            return nil
        }
    }

    /// The parts Open all opens, in order (a file still to be found by `located` and checked by `fileAction`).
    static func openable(_ items: [NoteContract.TaskItem]) -> [URL] { items.compactMap(url) }

    /// What Open all (or a note dropped on an app) may do with a file, decided on what it really is once its aliases
    /// and symbolic links are resolved: opened only when it's a document (conforms to `UTType.content`) and nothing
    /// that runs or points elsewhere (an app, an executable or script of any kind, a `.command`, `.tool`, `.workflow`
    /// or `.terminal` file, an installer package, a disk image, an alias or link, a web, internet or file location).
    /// Anything else is shown in Finder, selected, never opened.
    enum FileAction: Equatable { case open, reveal }

    static let neverOpened: Set<String> = ["app", "command", "tool", "workflow", "terminal", "pkg", "mpkg", "dmg", "sparseimage", "sparsebundle",
                                            "webloc", "inetloc", "fileloc", "sh", "zsh", "bash", "csh", "ksh", "py", "rb", "pl", "scpt", "scptd",
                                            "applescript", "action", "definition", "jar", "prefpane", "kext", "plugin", "bundle", "service", "framework",
                                            "dylib", "so", "osax", "mobileconfig", "xpc", "appex", "url", "alias", "saver", "qlgenerator", "mdimporter"]

    static let neverTypes: [String] = ["com.apple.application", "com.apple.application-bundle", "public.executable", "public.unix-executable",
                                       "public.script", "public.shell-script", "com.apple.applescript.script", "com.apple.applescript.script-bundle",
                                       "com.apple.applescript.text", "com.apple.terminal.shell-script", "com.apple.automator-workflow",
                                       "com.apple.terminal.session", "com.apple.terminal.settings", "com.apple.installer-package-archive",
                                       "com.apple.installer-meta-package", "com.apple.disk-image", "public.disk-image", "com.apple.alias-file",
                                       "public.symlink", "com.apple.web-internet-location", "com.apple.internet-location",
                                       "com.apple.file-internet-location", "com.apple.finder.file-location"]

    /// A file as it really is: its alias or symbolic links resolved, then what it is (`fileAction`). The resolved file
    /// is what's opened or shown. Off the main thread.
    nonisolated static func decide(_ url: URL) -> (URL, FileAction) {
        let resolved = (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url
        let real = resolved.resolvingSymlinksInPath()
        let values = try? real.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
        guard FileManager.default.fileExists(atPath: real.path), values?.isSymbolicLink != true, values?.isAliasFile != true else { return (real, .reveal) }
        return (real, fileAction(type: values?.contentType, ext: real.pathExtension, isDirectory: values?.isDirectory == true))
    }

    /// `type`: the resolved file's type; `isDirectory`: it's a folder (a document package, like Keynote's, is one).
    static func fileAction(type: UTType?, ext: String, isDirectory: Bool) -> FileAction {
        guard let type, type.conforms(to: .content), !neverOpened.contains(ext.lowercased()) else { return .reveal }
        for id in neverTypes { if let never = UTType(id), type.conforms(to: never) { return .reveal } }
        if isDirectory && !type.conforms(to: .package) { return .reveal }   // a folder is shown, never opened
        return .open
    }

    /// What a routine's open action may do with a file it names (Routines.perform), by Open all's own rule: a
    /// document is opened, an app is started, and anything else is left: never a script, a program, an installer
    /// or something that points elsewhere.
    enum RoutineFile: Equatable { case open, launch, never }

    static func routineFile(type: UTType?, ext: String, isDirectory: Bool) -> RoutineFile {
        if fileAction(type: type, ext: ext, isDirectory: isDirectory) == .open { return .open }
        if isDirectory, ext.lowercased() == "app", let type, type.conforms(to: .applicationBundle) { return .launch }
        return .never
    }

    /// A routine's file as it really is (its alias or symbolic links resolved, as `decide` does), and what a routine
    /// may do with it. Off the main thread.
    nonisolated static func routine(_ url: URL) -> (URL, RoutineFile) {
        let resolved = (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url
        let real = resolved.resolvingSymlinksInPath()
        let values = try? real.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
        guard FileManager.default.fileExists(atPath: real.path), values?.isSymbolicLink != true, values?.isAliasFile != true else { return (real, .never) }
        return (real, routineFile(type: values?.contentType, ext: real.pathExtension, isDirectory: values?.isDirectory == true))
    }

    /// A task's file as it is now, found by the one file resolver (ViewerFiles: the very file it was put away as, by
    /// its `fileID`, wherever it went; that gone, the one its bookmark finds; with no bookmark, the one at its path:
    /// never another file that took its path while its own still exists). A task that kept no identity (an older one,
    /// or one written by hand) goes by its path. Nil: no file to open (not a file's part, not a full path, or its
    /// file gone). Off the main thread. `mac`: this Mac's id; `follow`: a bookmark's file.
    nonisolated static func located(_ item: NoteContract.TaskItem, mac: String, follow: (Data) -> URL?) -> URL? {
        guard item.kind == "file", let named = url(item) else { return nil }
        var stick = NoteStick(kind: .file)
        stick.path = named.path
        stick.bookmark = item.bookmark
        stick.fileID = item.fileID
        return ViewerFiles.locate(stick, mac: mac, follow: follow).map { URL(fileURLWithPath: $0.path) }
    }

    /// Open all: each part of a task through the normal open paths: a tab (http or https only) in the person's
    /// browser, a mail (a `message:` address only) in Mail, a file in its own app only once it's found (`located`),
    /// resolved (aliases and symbolic links followed, off the main thread) and found to be a document (`fileAction`);
    /// anything else is shown in Finder, selected, never opened, and said. A window's app is only brought forward
    /// when it's already running (never launched). Asynchronous throughout (Launch Services never asked on the main
    /// thread to wait), never moving the pointer; nothing is sent or changed. Returns how many parts it will try.
    @MainActor @discardableResult
    static func openAll(_ items: [NoteContract.TaskItem], mac: String, follow: @escaping @Sendable (Data) -> URL?,
                        said: @escaping @MainActor (String) -> Void = { _ in }) -> Int {
        for item in items where item.kind == "window" {
            if let running = NSWorkspace.shared.personsApplications.first(where: { $0.bundleIdentifier == item.target && !$0.isTerminated }) { running.activate() }
        }
        let parts = items.filter { url($0) != nil }
        let skipped = items.filter { $0.kind != "window" }.count - parts.count
        DispatchQueue.global(qos: .userInitiated).async {
            // A file's part: where its file is now, then what it really is. One that's gone opens nothing.
            let decided = parts.map { item -> (URL, FileAction)? in
                if item.kind == "file" { return located(item, mac: mac, follow: follow).map(decide) }
                return url(item).map { ($0, FileAction.open) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let failed = Counter()
                    let group = DispatchGroup()
                    var revealed: [URL] = []
                    let gone = decided.filter { $0 == nil }.count
                    for case let (url, action)? in decided {
                        if action == .reveal { revealed.append(url); continue }
                        group.enter()
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                            if error != nil { failed.add() }
                            group.leave()
                        }
                    }
                    if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
                    group.notify(queue: .main) {
                        MainActor.assumeIsolated {
                            var words: [String] = []
                            if !revealed.isEmpty {
                                words.append(revealed.count == 1 ? "\(revealed[0].lastPathComponent) isn't a document, so Petal showed it in Finder instead of opening it."
                                                                 : "\(revealed.count) parts aren't documents, so Petal showed them in Finder instead of opening them.")
                            }
                            let missed = failed.value + skipped + gone
                            if missed > 0 { words.append(missed == 1 ? "One part couldn't be opened." : "\(missed) parts couldn't be opened.") }
                            if !words.isEmpty { said(words.joined(separator: " ")) }
                        }
                    }
                }
            }
        }
        return parts.count
    }

    /// A link a helper left (a pull request's address), or a link's card: opened only when it's http or https.
    @MainActor static func openWeb(_ link: String) {
        if let url = web(link) { NSWorkspace.shared.open(url) }
    }

    /// What a click on a link in a note's own words may do. A note's words can come from sync or a tool, like a
    /// task's parts, and a link shows only its words: a web address (http or https), a mail address (`mailto:`) or a
    /// mail by its message address (`message:`, as Open all opens it) opens; a file on this Mac (a `file:` address with a full path) goes by Open all's rule (`decide`: a document
    /// opens, anything else is shown in Finder); any other kind of address does nothing.
    enum LinkAction: Equatable { case open(URL), file(URL), nothing }

    static func link(_ link: Any) -> LinkAction {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased() else { return .nothing }
        switch scheme {
        case "http", "https": return web(url.absoluteString).map { .open($0) } ?? .nothing
        case "mailto", "message": return .open(url)
        case "file":
            guard url.isFileURL, ["", "localhost"].contains(url.host ?? ""), url.path.hasPrefix("/"), !url.path.contains("\0") else { return .nothing }
            return .file(URL(fileURLWithPath: url.path))
        default: return .nothing
        }
    }

    /// The click itself: a web or mail address opened; a file resolved and looked at off the main thread first
    /// (`decide`), then opened if it's a document, else shown in Finder, never opened; one that's gone does nothing.
    @MainActor static func openLink(_ link: Any) {
        switch NoteTasks.link(link) {
        case .open(let url): NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        case .file(let named):
            DispatchQueue.global(qos: .userInitiated).async {
                let (real, action) = decide(named)
                guard FileManager.default.fileExists(atPath: real.path) else { return }
                DispatchQueue.main.async {
                    if action == .open { NSWorkspace.shared.open(real, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) }
                    else { NSWorkspace.shared.activateFileViewerSelecting([real]) }
                }
            }
        case .nothing: break
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
