import Foundation

/// Where routines may take files from and file them into, as rules without AppKit (checked by
/// checks/RoutineRulesCheck.swift). A routine's folders are in the home folder, never all of it, its Library or a
/// hidden folder: by their paths as written when it's saved or read (`allowed`), and again by where they really are,
/// every link followed, right before each file moves (`refusal`), so a link that turns up in a tidied folder never
/// sends a file somewhere else.
enum RoutineRules {
    /// The temporary folders, which a check's routines may use (`testing`).
    static let temporary = ["/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"]

    /// A folder by its path: inside the home folder, and not all of it, its Library or a hidden folder.
    static func allowed(_ path: String, home: String, testing: Bool) -> Bool {
        let hidden = { (parts: [Substring]) in parts.contains { $0.hasPrefix(".") } }
        if testing, temporary.contains(where: path.hasPrefix) { return !hidden(path.split(separator: "/")) }
        guard path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        return !parts.isEmpty && parts[0].lowercased() != "library" && !hidden(parts)
    }

    /// A path as it really is on the disk, every link in it followed. A folder that isn't made yet is the nearest
    /// one above it that is there, as it really is, with the rest of the path after it. Nil: something in the path
    /// is there but leads nowhere that can be read (a link to nothing): not a place to file into.
    static func real(_ path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        var rest: [String] = []
        while true {
            if let resolved = realpath(current, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/")
            }
            var info = stat()
            if lstat(current, &info) == 0 || current == "/" { return nil }
            rest.insert((current as NSString).lastPathComponent, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// A place as it really is (`real`) that routines may move files out of or into: one `allowed` by the home
    /// folder as it really is, or inside one of the cloud folders macOS keeps under the home's Library/CloudStorage
    /// (where ~/Dropbox, ~/Google Drive and ~/OneDrive really are).
    static func reaches(_ real: String, home: String, testing: Bool) -> Bool {
        if allowed(real, home: home, testing: testing) { return true }
        let cloud = home + "/Library/CloudStorage/"
        guard real.hasPrefix(cloud) else { return false }
        let parts = real.dropFirst(cloud.count).split(separator: "/")
        return !parts.isEmpty && !parts.contains { $0.hasPrefix(".") }
    }

    /// The thing at `path` is itself a link (never followed to find out).
    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Why a file isn't moved.
    enum Refusal: Equatable {
        case fileIsLink     // it's a link, not a file of its own
        case from           // its folder really is somewhere routines don't tidy
        case into           // the folder it would go into really is somewhere routines don't file into
        case linkedFolder   // the subfolder it would go into is a link, not a folder
    }

    /// Why `file` isn't moved into `folder`, or nil when it may be. `root` is the folder the routine itself names
    /// (where it moves files, or where its subfolders go); `folder` is that one, or a subfolder under it that Petal
    /// files into (Images, Receipts). The routine's own folder may be a link the person keeps (~/Dropbox) as long as
    /// it really is somewhere routines may file into; a subfolder under it is one Petal made or found as a folder,
    /// never a link by that name. `home`: the home folder as written.
    static func refusal(moving file: String, into folder: String, under root: String, home: String, testing: Bool) -> Refusal? {
        guard !isLink(file) else { return .fileIsLink }
        guard let home = real(home) else { return .from }
        guard let from = real((file as NSString).deletingLastPathComponent), reaches(from, home: home, testing: testing) else { return .from }
        let plain = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.path }
        var step = plain(folder)
        let top = plain(root)
        if step != top {
            guard step.hasPrefix(top + "/") else { return .into }
            while step != top {
                if isLink(step) { return .linkedFolder }
                step = (step as NSString).deletingLastPathComponent
            }
        }
        guard let into = real(folder), reaches(into, home: home, testing: testing) else { return .into }
        return nil
    }

    // MARK: What a routine opens, and when it asks first

    /// One thing a routine's open action names: an app by its bundle id, a web address (http or https, with a
    /// host), a file by its full path, or nothing a routine opens. A file is opened only once it's found to be a
    /// document, or started when it's an app (NoteTasks.routine: Open all's own rule), never a script or a program;
    /// any other kind of address (another app's own links, mail, a Shortcut's) is nothing.
    enum Opens: Equatable {
        case app(String)
        case web(URL)
        case file(String)
        case nothing
    }

    static func opens(_ item: String) -> Opens {
        let item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty, !item.contains("\0") else { return .nothing }
        if item.hasPrefix("/") || item.hasPrefix("~") { return .file((item as NSString).expandingTildeInPath) }
        guard item.contains(":") else { return .app(item) }
        guard let url = URL(string: item), let scheme = url.scheme?.lowercased() else { return .nothing }
        if scheme == "file" { return url.path.hasPrefix("/") ? .file(url.path) : .nothing }
        guard scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return .nothing }
        return .web(url)
    }

    /// A routine with one of these actions goes on opening things or running a Shortcut by itself, so the person is
    /// asked before Petal AI saves it, changes it or runs it (Petal AI's card, kind `routine`).
    static func asksFirst(actions kinds: [String]) -> Bool {
        kinds.contains { $0 == "open" || $0 == "shortcut" }
    }

    /// Whether saving a routine asks: it would open something or run a Shortcut, and this isn't only a new name or
    /// new words for one that does the same already, or turning it off. `same`: its trigger and actions are the ones
    /// it has now.
    static func savingAsks(actions kinds: [String], same: Bool, wasOn: Bool, on: Bool) -> Bool {
        guard asksFirst(actions: kinds) else { return false }
        return !same || (on && !wasOn)
    }
}
