import Foundation

// Checks DockImport.swift: importing macOS's Dock replaces Petal's dock only on the first setup, and otherwise adds
// what's missing, apps and folders both, after what the person has, never removing or moving anything of theirs.
// Pure. Run with macos/checks/run.sh.

@main
struct DockImportCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; print("FAIL: \(what)") }
    }

    static func main() {
        let system = ["com.apple.Safari", "com.apple.mail", "com.apple.Music"], systemFolders = ["~/Downloads", "~/Documents"]

        let first = DockImport.merge(apps: [], folders: ["~/Downloads", "~/Pictures/Screenshots"], systemApps: system, systemFolders: systemFolders, firstSetup: true)
        expect(first.apps == system && first.folders == systemFolders, "the first setup takes macOS's Dock whole")
        let bare = DockImport.merge(apps: [], folders: ["~/Downloads"], systemApps: system, systemFolders: [], firstSetup: true)
        expect(bare.folders == ["~/Downloads"], "the first setup keeps Petal's stacks when macOS's Dock has no folders")

        // Not the first setup, no apps kept but stacks of the person's own: the stacks stay, macOS's are added.
        let stacksOnly = DockImport.merge(apps: [], folders: ["~/Projects", "~/Downloads"], systemApps: system, systemFolders: systemFolders, firstSetup: false)
        expect(stacksOnly.apps == system, "an empty dock after the welcome gets macOS's apps")
        expect(stacksOnly.folders == ["~/Projects", "~/Downloads", "~/Documents"], "the person's stacks stay, in order, and only new folders are added")

        let mine = DockImport.merge(apps: ["com.figma.Desktop", "com.apple.mail", "https://example.com"], folders: ["~/Downloads"],
                                    systemApps: system, systemFolders: systemFolders, firstSetup: false)
        expect(mine.apps == ["com.figma.Desktop", "com.apple.mail", "https://example.com", "com.apple.Safari", "com.apple.Music"],
               "the person's apps stay in their order, and macOS's missing ones follow")
        expect(mine.folders == ["~/Downloads", "~/Documents"], "a folder already a stack isn't added again")

        // Folders are the same by where they really are; the person's own duplicates are never taken out.
        let key: (String) -> String = { $0 == "~/Pictures/Screenshots" ? "~/Desktop" : $0 }
        let resolved = DockImport.merge(apps: ["a"], folders: ["~/Pictures/Screenshots", "~/Desktop"], systemApps: [], systemFolders: ["~/Desktop", "~/Desktop"],
                                        firstSetup: false, key: key)
        expect(resolved.folders == ["~/Pictures/Screenshots", "~/Desktop"], "a folder shown as another stack isn't added, and the person's stacks stay whole")
        let twice = DockImport.merge(apps: ["a"], folders: [], systemApps: ["b", "b"], systemFolders: ["~/X", "~/X"], firstSetup: false)
        expect(twice.apps == ["a", "b"] && twice.folders == ["~/X"], "what macOS's Dock lists twice is added once")
        let again = DockImport.merge(apps: mine.apps, folders: mine.folders, systemApps: system, systemFolders: systemFolders, firstSetup: false)
        expect(again.apps == mine.apps && again.folders == mine.folders, "importing twice changes nothing the second time")

        if failures > 0 { print("dock import: \(failures) failed"); exit(1) }
        print("dock import: replaces only on the first setup; otherwise adds what's missing and keeps everything the person has")
    }
}
