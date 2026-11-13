import Foundation

/// What "Import macOS's Dock" makes of Petal's dock. Pure, checked by `macos/checks/run.sh`; `Config.importSystemDock`
/// reads both docks and writes the result.
enum DockImport {
    /// - `apps`, `folders`: Petal's dock now (its apps in order, and its stacks).
    /// - `systemApps`, `systemFolders`: macOS's Dock's.
    /// - `firstSetup`: the welcome isn't finished yet, so nothing of the person's is in Petal's dock to keep.
    /// - `key`: what makes two folders the same one (where each stack really is).
    ///
    /// On the first setup macOS's Dock becomes Petal's: its apps in its order, and its folders as the stacks (Petal's
    /// own stacks stay when macOS's Dock has none). Every other time it only adds: macOS's apps and folders that
    /// Petal's dock doesn't have, after the ones it has, each once; nothing the person has is moved or removed.
    static func merge(apps: [String], folders: [String], systemApps: [String], systemFolders: [String], firstSetup: Bool,
                      key: (String) -> String = { $0 }) -> (apps: [String], folders: [String]) {
        if firstSetup { return (adding(systemApps, to: [], key: { $0 }), systemFolders.isEmpty ? folders : adding(systemFolders, to: [], key: key)) }
        return (adding(systemApps, to: apps, key: { $0 }), adding(systemFolders, to: folders, key: key))
    }

    /// `kept` exactly as it is, then each of `new` whose key isn't there yet, once, in order.
    private static func adding(_ new: [String], to kept: [String], key: (String) -> String) -> [String] {
        var seen = Set(kept.map(key))
        return kept + new.filter { seen.insert(key($0)).inserted }
    }
}
