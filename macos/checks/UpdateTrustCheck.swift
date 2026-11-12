import Foundation

// Checks UpdateTrust.swift, which decides whether a downloaded Petal may be installed: a bundle signed as asked is
// accepted; one signed as something else, one changed after it was signed and one never signed are refused;
// nothing signed ad hoc is ever Petal's maker's; and only a release that may be installed says which source an
// update with the person's own changes is built from. It makes its own tiny bundles in the temporary folder and signs
// them ad hoc with `codesign`; it never touches a Petal. Run with macos/checks/run.sh.

@main
struct UpdateTrustCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; print("FAIL: \(what)") }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A bundle with a program and one resource, signed ad hoc under `identifier` (nil: left unsigned), saying it's
    /// `version` when given.
    static func bundle(_ name: String, in folder: URL, identifier: String?, version: String? = nil, commit: String? = nil) -> URL {
        let app = folder.appending(path: "\(name).app")
        let contents = app.appending(path: "Contents")
        try? FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(identifier ?? "check.unsigned")</string>
        <key>CFBundleExecutable</key><string>\(name)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        \(version.map { "<key>CFBundleShortVersionString</key><string>\($0)</string>" } ?? "")
        \(commit.map { "<key>PetalSourceCommit</key><string>\($0)</string>" } ?? "")
        </dict></plist>
        """
        try? Data(plist.utf8).write(to: contents.appending(path: "Info.plist"))
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appending(path: "MacOS/\(name)"))
        try? Data("as signed\n".utf8).write(to: contents.appending(path: "Resources/words.txt"))
        if let identifier {
            // /usr/bin/true comes with Apple's signature: taken off first, so the bundle's only signature is this one.
            run("/usr/bin/codesign", ["--remove-signature", contents.appending(path: "MacOS/\(name)").path])
            expect(run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path]) == 0, "codesign signs \(name)")
        } else {
            run("/usr/bin/codesign", ["--remove-signature", contents.appending(path: "MacOS/\(name)").path])
        }
        return app
    }

    static func main() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-update-trust-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let ours = bundle("Ours", in: folder, identifier: "check.petal.ours")
        let theirs = bundle("Theirs", in: folder, identifier: "check.petal.theirs")
        let unsigned = bundle("Unsigned", in: folder, identifier: nil)
        let asked = #"identifier "check.petal.ours""#

        expect(UpdateTrust.signed(ours, as: asked), "a bundle signed as asked is accepted")
        expect(!UpdateTrust.signed(theirs, as: asked), "a bundle signed as something else is refused")
        expect(!UpdateTrust.signed(unsigned, as: asked), "a bundle that was never signed is refused")
        expect(!UpdateTrust.signed(folder.appending(path: "Missing.app"), as: asked), "a bundle that isn't there is refused")
        expect(!UpdateTrust.signed(ours, as: "not a requirement at all"), "words that aren't a requirement accept nothing")

        // Changed after it was signed: a resource, then the program itself.
        let resource = bundle("Resource", in: folder, identifier: "check.petal.ours")
        expect(UpdateTrust.signed(resource, as: asked), "the second bundle is accepted before it's changed")
        try? Data("changed since\n".utf8).write(to: resource.appending(path: "Contents/Resources/words.txt"))
        expect(!UpdateTrust.signed(resource, as: asked), "a bundle with a resource changed after signing is refused")
        let added = bundle("Added", in: folder, identifier: "check.petal.ours")
        try? Data("slipped in\n".utf8).write(to: added.appending(path: "Contents/Resources/extra.txt"))
        expect(!UpdateTrust.signed(added, as: asked), "a bundle with a file added after signing is refused")

        // Petal's maker's signature can't be made here: a bundle with Petal's own identifier, signed ad hoc, is refused.
        let pretender = bundle("Pretender", in: folder, identifier: "tech.edgetr.petal")
        expect(UpdateTrust.signed(pretender, as: #"identifier "tech.edgetr.petal""#), "the pretender does carry Petal's identifier")
        expect(!UpdateTrust.signed(pretender), "a bundle with Petal's identifier but not its certificate is refused")
        expect(UpdateTrust.maker.contains(#"identifier "tech.edgetr.petal""#) && UpdateTrust.maker.contains("certificate root = H\""),
               "the maker's requirement names Petal's identifier and a certificate")

        // A release's version: plain numbers only, before it's used for anything.
        for good in ["2.1.4", "2", "10.0", "2.1.4.1", "999999.0.1"] { expect(UpdateTrust.plainVersion(good), "\(good) is a plain version") }
        for bad in ["", "2.1.4\n", " 2.1.4", "9.0/../../../Applications/Petal.app", "2..1", ".2.1", "2.1.", "v2.1.4", "2.1.4-beta",
                    "１.２.３", "٢.١", "1234567.0", "1.2.3.4.5", "2.1.4/", "2.1.4%2F..", "~"] {
            expect(!UpdateTrust.plainVersion(bad), "\(bad.debugDescription) is refused as a version")
        }
        expect(UpdateTrust.newer("2.1.10", than: "2.1.9") && UpdateTrust.newer("2.2", than: "2.1.9") && UpdateTrust.newer("3", than: "2.9.9"),
               "newer reads versions as numbers")
        expect(!UpdateTrust.newer("2.1.3", than: "2.1.3") && !UpdateTrust.newer("2.1.2", than: "2.1.3") && !UpdateTrust.newer("2.1", than: "2.1.0"),
               "the same or an older version isn't newer")

        // The very version its release said, and for an update, newer than the one running: never an older build of the
        // maker's handed over under a newer number.
        let release = bundle("Release", in: folder, identifier: "check.petal.ours", version: "2.1.4")
        expect(UpdateTrust.version(of: release) == "2.1.4", "a bundle's version is read from its Info.plist")
        expect(UpdateTrust.release(release, is: "2.1.4", as: asked), "the release its manifest said is accepted")
        expect(!UpdateTrust.release(release, is: "2.1.5", as: asked), "a bundle that isn't the version its manifest said is refused")
        expect(!UpdateTrust.release(release, is: "2.1.4/../2.1.4", as: asked), "a version that isn't plain is refused, whatever the bundle says")
        expect(!UpdateTrust.release(theirs, is: "2.1.4", as: asked), "the right version signed as something else is refused")
        expect(UpdateTrust.update(release, is: "2.1.4", over: "2.1.3", as: asked), "a newer release is an update")
        expect(!UpdateTrust.update(release, is: "2.1.4", over: "2.1.4", as: asked), "the version running isn't an update")
        expect(!UpdateTrust.update(release, is: "2.1.4", over: "2.2.0", as: asked), "an older release is never installed as an update")
        let old = bundle("Old", in: folder, identifier: "check.petal.ours", version: "2.1.2")
        expect(!UpdateTrust.update(old, is: "9.9.9", over: "2.1.3", as: asked), "an older build under a newer number is refused")
        let relabelled = bundle("Relabelled", in: folder, identifier: "check.petal.ours", version: "2.1.2")
        let info = relabelled.appending(path: "Contents/Info.plist")
        if let text = try? String(contentsOf: info, encoding: .utf8) {
            try? Data(text.replacingOccurrences(of: "2.1.2", with: "9.9.9").utf8).write(to: info)
        }
        expect(UpdateTrust.version(of: relabelled) == "9.9.9" && !UpdateTrust.update(relabelled, is: "9.9.9", over: "2.1.3", as: asked),
               "a version changed in a bundle after it was signed is refused")
        let unversioned = bundle("Unversioned", in: folder, identifier: "check.petal.ours")
        expect(!UpdateTrust.release(unversioned, is: "2.1.4", as: asked), "a bundle that says no version is refused")

        // An update rebuilt with the person's own changes: its source is the commit the release's own app says, and
        // only when that app is one an update may install.
        let sha = "0123456789abcdef0123456789abcdef01234567"
        expect(UpdateTrust.plainCommit(sha), "40 lowercase hex characters are a commit")
        let short = String(sha.dropLast())
        let notCommits: [String] = ["", "main", short, "\(sha)0", sha.uppercased(), "\(short)g", "\(short)\n", "refs/tags/macos-v2.1.4",
                                    "\(sha.dropLast(8))/../../x", "\(short)１", " \(short)"]
        for bad in notCommits {
            expect(!UpdateTrust.plainCommit(bad), "\(bad.debugDescription) is refused as a commit")
        }
        let built = bundle("Built", in: folder, identifier: "check.petal.ours", version: "2.1.4", commit: sha)
        expect(UpdateTrust.commit(of: built) == sha, "a bundle's commit is read from its Info.plist")
        expect(UpdateTrust.source(of: built, is: "2.1.4", over: "2.1.3", as: asked) == sha, "a release that may be installed gives its commit")
        expect(UpdateTrust.source(of: built, is: "2.1.5", over: "2.1.3", as: asked) == nil, "not when it isn't the version its release said")
        expect(UpdateTrust.source(of: built, is: "2.1.4", over: "2.1.4", as: asked) == nil, "not when it isn't newer than the one running")
        expect(UpdateTrust.source(of: built, is: "2.1.4", over: "2.1.3", as: #"identifier "check.petal.theirs""#) == nil, "not when it's signed as something else")
        expect(UpdateTrust.source(of: release, is: "2.1.4", over: "2.1.3", as: asked) == nil, "a release that names no commit gives none")
        let branch = bundle("Branch", in: folder, identifier: "check.petal.ours", version: "2.1.4", commit: "main")
        expect(UpdateTrust.source(of: branch, is: "2.1.4", over: "2.1.3", as: asked) == nil, "a name that isn't a whole commit gives none")
        let elsewhere = bundle("Elsewhere", in: folder, identifier: "check.petal.ours", version: "2.1.4", commit: "0123456789abcdef/../../other/repo/archive/x")
        expect(UpdateTrust.source(of: elsewhere, is: "2.1.4", over: "2.1.3", as: asked) == nil, "nor does anything else in its place")
        let repointed = bundle("Repointed", in: folder, identifier: "check.petal.ours", version: "2.1.4", commit: sha)
        let repointedInfo = repointed.appending(path: "Contents/Info.plist")
        if let text = try? String(contentsOf: repointedInfo, encoding: .utf8) {
            try? Data(text.replacingOccurrences(of: sha, with: String(sha.reversed())).utf8).write(to: repointedInfo)
        }
        expect(UpdateTrust.commit(of: repointed) == String(sha.reversed()) && UpdateTrust.source(of: repointed, is: "2.1.4", over: "2.1.3", as: asked) == nil,
               "a commit changed in a bundle after it was signed gives none")
        let unsignedBuild = bundle("UnsignedBuild", in: folder, identifier: nil, version: "2.1.4", commit: sha)
        expect(UpdateTrust.source(of: unsignedBuild, is: "2.1.4", over: "2.1.3", as: asked) == nil, "a bundle that was never signed gives none")

        if failures > 0 { print("\(failures) update trust check(s) failed"); exit(1) }
        print("update trust: all checks passed")
    }
}
