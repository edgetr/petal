import AppKit
import UniformTypeIdentifiers

/// Open all on a task put away, and anything a helper opens from a note's text: never an app or a script, since a
/// task's `url_or_path` (and a helper's link) can come from sync or a tool. A file is resolved first (aliases and
/// symbolic links, off the main thread) and opened only when what it really is is content and none of the kinds
/// that run something (an app, an executable or script, a .command, .tool, .workflow or .terminal file, an installer
/// package, a disk image, an alias, a link, or a .webloc, .inetloc or .fileloc); anything else is revealed in
/// Finder, never opened. Tabs open only for http and https; mail only for message:. (The same rule and name as Petal
/// Notes' window, Phase 3.)
enum NoteTasks {
    enum Action: Equatable { case open(URL), reveal(URL), skip }

    /// What runs something, or leads somewhere else, when opened: never opened, only revealed.
    static let blockedTypes: [UTType] = {
        var types: [UTType] = [.application, .applicationBundle, .executable, .unixExecutable, .script, .shellScript, .appleScript,
                               .diskImage, .aliasFile, .symbolicLink, .internetLocation]
        for id in ["com.apple.installer-package-archive", "com.apple.installer-meta-package", "com.apple.terminal.shell-script",
                   "com.apple.automator-workflow", "com.apple.terminal.settings", "com.apple.web-internet-location",
                   "com.apple.internet-location", "com.apple.finder.file-location", "com.apple.applescript.script",
                   "com.apple.applescript.script-bundle", "com.apple.applescript.text"] {
            if let type = UTType(id) { types.append(type) }
        }
        return types
    }()

    /// The same kinds by their file extensions (a file may say it's something else).
    static let blockedExtensions: Set<String> = ["app", "command", "tool", "workflow", "terminal", "pkg", "mpkg", "dmg", "sh", "bash", "zsh",
                                                 "csh", "ksh", "py", "rb", "pl", "scpt", "scptd", "applescript", "webloc", "inetloc",
                                                 "fileloc", "alias", "action", "definition", "jar"]

    /// Whether a file of this resolved type and extension is opened (else it's revealed).
    static func opens(type: UTType?, ext: String) -> Bool {
        guard let type, type.conforms(to: .content), !blockedExtensions.contains(ext.lowercased()) else { return false }
        return !blockedTypes.contains { type.conforms(to: $0) }
    }

    /// An address a helper may open: http or https only.
    static func web(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// What Open all does with one part: a tab opens only for http and https, mail only for message:, a file
    /// (already resolved: `resolved` and its `type`) opens only when it's safe content, else it's revealed; a file
    /// that isn't there, and a window, open nothing.
    static func action(_ item: NoteHelp.TaskItem, resolved: URL?, type: UTType?) -> Action {
        switch item.kind {
        case .tab: return web(item.target).map(Action.open) ?? .skip
        case .mail:
            guard let url = URL(string: item.target), url.scheme?.lowercased() == "message" else { return .skip }
            return .open(url)
        case .file:
            guard let resolved else { return .skip }
            return opens(type: type, ext: resolved.pathExtension) ? .open(resolved) : .reveal(resolved)
        case .window: return .skip
        }
    }

    /// A file's path resolved (symbolic links, then a Finder alias, then links again) and what it really is. Off the
    /// main thread: the disk (and an alias's volume) may be slow.
    nonisolated static func resolve(_ path: String) -> (url: URL, type: UTType?)? {
        guard path.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true, let target = try? URL(resolvingAliasFileAt: url) {
            url = target.resolvingSymlinksInPath()
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType)
    }

    /// Open all: each part resolved off the main thread, then opened or revealed by the rule. A window's app is
    /// brought forward only when it's already running (never launched).
    @MainActor static func openAll(_ items: [NoteHelp.TaskItem]) {
        for item in items where item.kind == .window {
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == item.target && !$0.isTerminated }) { running.activate() }
        }
        let rest = items.filter { $0.kind != .window }
        DispatchQueue.global(qos: .userInitiated).async {
            let actions = rest.map { item -> Action in
                let found = item.kind == .file ? resolve(item.target) : nil
                return action(item, resolved: found?.url, type: found?.type)
            }
            DispatchQueue.main.async {
                var reveal: [URL] = []
                for action in actions {
                    switch action {
                    case .open(let url): NSWorkspace.shared.open(url)
                    case .reveal(let url): reveal.append(url)
                    case .skip: break
                    }
                }
                if !reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(reveal) }
            }
        }
    }

    /// A link a helper left (a pull request's address): opened only when it's http or https.
    @MainActor static func openWeb(_ link: String) {
        if let url = web(link) { NSWorkspace.shared.open(url) }
    }
}
