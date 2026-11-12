import Foundation

// Checks RoutineRules.swift: where routines may take files from and file them into, by a folder's path and by where
// it really is once every link is followed. On throwaway folders it makes in the temporary folder; nothing is ever
// moved (the rule only answers). Run with macos/checks/run.sh.
@main
struct RoutineRulesCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        let fm = FileManager.default
        // By its path as written.
        let home = "/Users/someone"
        func allowed(_ path: String, testing: Bool = false) -> Bool { RoutineRules.allowed(path, home: home, testing: testing) }
        expect(allowed("/Users/someone/Downloads") && allowed("/Users/someone/Documents/Receipts/2026"), "folders in the home folder")
        expect(!allowed("/Users/someone") && !allowed("/Users/someone/"), "never all of the home folder")
        expect(!allowed("/Users/someone/Library") && !allowed("/Users/someone/Library/LaunchAgents") && !allowed("/Users/someone/library/LaunchAgents"),
               "never its Library, however it's spelled")
        expect(!allowed("/Users/someone/.ssh") && !allowed("/Users/someone/Documents/.hidden/x"), "never a hidden folder")
        expect(!allowed("/etc") && !allowed("/Users/other/Downloads") && !allowed("/Users/someone2/Downloads") && !allowed("/Volumes/Disk/x"), "never outside the home folder")
        expect(!allowed("/private/var/folders/ab/T/check/Inbox") && allowed("/private/var/folders/ab/T/check/Inbox", testing: true)
               && allowed("/tmp/check/Inbox", testing: true), "the temporary folders only for a check")
        expect(!allowed("/private/var/folders/ab/T/check/.kept/Inbox", testing: true), "and never a hidden folder there either")

        // A throwaway home, as it really is on the disk.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-routine-rules-\(getpid())")
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }
        func folder(_ path: String) -> String {
            let url = base.appending(path: path)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        func file(_ path: String) -> String {
            let url = base.appending(path: path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data("x".utf8))
            return url.path
        }
        func link(_ path: String, to target: String) -> String {
            let url = base.appending(path: path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            return url.path
        }
        let me = folder("Users/me")
        let downloads = folder("Users/me/Downloads")
        _ = folder("Users/me/Library/LaunchAgents")
        _ = folder("Users/me/Library/CloudStorage/Dropbox/Receipts")
        _ = folder("Users/me/.config/petal")
        _ = folder("Users/me/Documents/Taxes")
        let outside = folder("Elsewhere/Stuff")
        let photo = file("Users/me/Downloads/photo.png")
        let plist = file("Users/me/Downloads/x.plist")
        func refusal(_ file: String, into folder: String, under root: String? = nil) -> RoutineRules.Refusal? {
            RoutineRules.refusal(moving: file, into: folder, under: root ?? folder, home: me, testing: false)
        }
        guard let realHome = RoutineRules.real(me), let realOutside = RoutineRules.real(outside) else {
            print("FAIL the check's own folders can't be read"); exit(1)
        }

        // Where a path really is.
        expect(RoutineRules.real(downloads) == realHome + "/Downloads", "a real folder is itself")
        expect(RoutineRules.real(downloads + "/Images/2026") == realHome + "/Downloads/Images/2026", "a folder not made yet is under the nearest one that's there")
        let toOutside = link("Users/me/Downloads/Other", to: "../../../Elsewhere/Stuff")
        expect(RoutineRules.real(toOutside) == realOutside && RoutineRules.real(toOutside + "/New") == realOutside + "/New", "a link is where it leads, and so is what's under it")
        let nowhere = link("Users/me/Downloads/Gone", to: "../nothing/here")
        expect(RoutineRules.real(nowhere) == nil && RoutineRules.real(nowhere + "/x") == nil, "a link to nothing is nowhere")
        expect(RoutineRules.isLink(toOutside) && RoutineRules.isLink(nowhere) && !RoutineRules.isLink(downloads) && !RoutineRules.isLink(downloads + "/missing"),
               "a link is told from a folder without following it")

        // Moves that stay in the home folder.
        expect(refusal(photo, into: downloads + "/Images", under: downloads) == nil, "a file into a kind folder not made yet")
        _ = folder("Users/me/Downloads/Images")
        expect(refusal(photo, into: downloads + "/Images", under: downloads) == nil, "and into one that's there")
        expect(refusal(photo, into: me + "/Documents/Taxes") == nil, "a file into the folder the routine names")
        expect(refusal(photo, into: me + "/Documents/Taxes/2026/Q4") == nil, "and into one it names that isn't made yet")

        // A link where a subfolder Petal files into would be: never followed, wherever it leads.
        expect(refusal(plist, into: toOutside, under: downloads) == .linkedFolder, "a kind folder that is a link out of the home folder", "\(String(describing: refusal(plist, into: toOutside, under: downloads)))")
        let toLibrary = link("Users/me/Downloads/Code", to: "../Library/LaunchAgents")
        expect(refusal(plist, into: toLibrary, under: downloads) == .linkedFolder, "a kind folder that is a link into Library")
        let toTaxes = link("Users/me/Downloads/Documents", to: "../Documents/Taxes")
        expect(refusal(plist, into: toTaxes, under: downloads) == .linkedFolder, "a kind folder that is a link to another folder of the person's")
        expect(refusal(plist, into: nowhere, under: downloads) == .linkedFolder, "a kind folder that is a link to nothing")

        // The folder a routine names may be a link the person keeps, as long as it really is somewhere routines file into.
        let dropbox = link("Users/me/Dropbox", to: "Library/CloudStorage/Dropbox")
        expect(refusal(photo, into: dropbox) == nil && refusal(photo, into: dropbox + "/Receipts", under: dropbox) == nil
               && refusal(photo, into: dropbox + "/New", under: dropbox) == nil, "a cloud folder the person keeps as a link in the home folder")
        let shelf = link("Users/me/Shelf", to: "Documents/Taxes")
        expect(refusal(photo, into: shelf) == nil, "a link to another folder in the home folder")
        let agents = link("Users/me/Agents", to: "Library/LaunchAgents")
        expect(refusal(plist, into: agents) == .into && refusal(plist, into: agents + "/New", under: agents) == .into, "a named folder that really is in Library")
        let away = link("Users/me/Away", to: "../../Elsewhere/Stuff")
        expect(refusal(plist, into: away) == .into, "a named folder that really is outside the home folder")
        let dotted = link("Users/me/Settings", to: ".config/petal")
        expect(refusal(plist, into: dotted) == .into, "a named folder that really is a hidden one")
        let through = link("Users/me/Documents/Out", to: "../../../Elsewhere")
        expect(refusal(plist, into: through + "/Stuff") == .into && refusal(plist, into: through + "/New/Deeper") == .into, "a named folder reached through a link out of the home folder")
        expect(refusal(plist, into: me + "/Library/LaunchAgents") == .into && refusal(plist, into: outside) == .into && refusal(plist, into: me) == .into,
               "a named folder that isn't one routines file into, link or not")
        expect(refusal(plist, into: outside + "/Deeper", under: downloads) == .into, "a folder that isn't under the routine's own")

        // The file itself, and where it's taken from.
        let linkedFile = link("Users/me/Downloads/passwd.txt", to: "/etc/passwd")
        expect(refusal(linkedFile, into: downloads + "/Documents2", under: downloads) == .fileIsLink, "a link among the files is never moved")
        let strayFile = file("Elsewhere/Stuff/theirs.txt")
        expect(refusal(strayFile, into: me + "/Documents/Taxes") == .from, "a file outside the home folder is never taken")
        let inbox = link("Users/me/Inbox", to: "../../Elsewhere/Stuff")
        expect(refusal(inbox + "/theirs.txt", into: me + "/Documents/Taxes") == .from, "nor through a link that leaves the home folder")
        let library = file("Users/me/Library/LaunchAgents/own.plist")
        expect(refusal(library, into: me + "/Documents/Taxes") == .from, "nor out of Library")
        let cloudFile = file("Users/me/Library/CloudStorage/Dropbox/scan.pdf")
        expect(refusal(dropbox + "/scan.pdf", into: dropbox + "/Receipts", under: dropbox) == nil && FileManager.default.fileExists(atPath: cloudFile),
               "a file in the person's cloud folder is tidied there")

        print("routine rules: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
