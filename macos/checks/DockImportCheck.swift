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

        // A first setup into a dock that already has apps (an older Petal used without finishing the welcome) keeps them.
        let early = DockImport.merge(apps: ["com.figma.Desktop"], folders: ["~/Projects"], systemApps: system, systemFolders: systemFolders, firstSetup: true)
        expect(early.apps == ["com.figma.Desktop"] + system && early.folders == ["~/Projects"] + systemFolders,
               "a first setup keeps the apps already in Petal's dock, and adds macOS's after them")

        // Swept: thousands of docks, with repeats, web addresses and folders that are one another.
        var random = SystemRandomNumberGenerator()
        let pool = ["com.apple.Safari", "com.apple.mail", "com.apple.Music", "com.figma.Desktop", "https://example.com", "com.apple.finder", "x"]
        let folderPool = ["~/Downloads", "~/Documents", "~/Desktop", "~/Pictures/Screenshots", "/Applications", "~/Projects"]
        let same: (String) -> String = { $0 == "~/Pictures/Screenshots" ? "~/Desktop" : $0 }
        func some(_ from: [String]) -> [String] { (0..<Int.random(in: 0...6, using: &random)).map { _ in from.randomElement(using: &random)! } }
        for _ in 0..<5000 {
            let apps = some(pool), folders = some(folderPool), systemApps = some(pool), systemFolders = some(folderPool)
            let firstSetup = Bool.random(using: &random)
            let r = DockImport.merge(apps: apps, folders: folders, systemApps: systemApps, systemFolders: systemFolders, firstSetup: firstSetup, key: same)
            let replaced = firstSetup && apps.isEmpty
            let what = "apps \(apps) folders \(folders) + \(systemApps) \(systemFolders) first \(firstSetup) -> \(r)"
            expect(Set(apps).isSubset(of: r.apps) && Set(systemApps).isSubset(of: r.apps), "an import never loses an app, and brings each of macOS's: \(what)")
            expect(Set(systemFolders.map(same)).isSubset(of: r.folders.map(same)), "every folder of macOS's Dock is a stack after: \(what)")
            if !replaced {
                expect(Array(r.apps.prefix(apps.count)) == apps, "the person's apps stay whole, in their order: \(what)")
                expect(Array(r.folders.prefix(folders.count)) == folders, "the person's stacks stay whole, in their order: \(what)")
            } else if systemFolders.isEmpty {
                expect(r.folders == folders, "a first setup keeps Petal's stacks when macOS's Dock has none: \(what)")
            }
            let added = r.apps.dropFirst(replaced ? 0 : apps.count), addedFolders = r.folders.dropFirst(replaced && !systemFolders.isEmpty ? 0 : folders.count)
            expect(Set(added).count == added.count && Set(added).isDisjoint(with: replaced ? [] : apps), "an app is added once: \(what)")
            expect(Set(addedFolders.map(same)).count == addedFolders.count, "a folder is added once: \(what)")
            let again = DockImport.merge(apps: r.apps, folders: r.folders, systemApps: systemApps, systemFolders: systemFolders, firstSetup: false, key: same)
            expect(again.apps == r.apps && again.folders == r.folders, "importing again changes nothing: \(what)")
            let twice = DockImport.merge(apps: r.apps, folders: r.folders, systemApps: systemApps, systemFolders: systemFolders, firstSetup: true, key: same)
            expect(r.apps.isEmpty || (twice.apps == r.apps && twice.folders == r.folders),
                   "pressed twice before the welcome is done, the second changes nothing: \(what)")
            if failures > 20 { break }
        }

        if failures > 0 { print("dock import: \(failures) failed"); exit(1) }
        print("dock import: replaces only on the first setup; otherwise adds what's missing and keeps everything the person has")
    }
}
