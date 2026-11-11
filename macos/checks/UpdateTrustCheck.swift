import Foundation

// Checks UpdateTrust.swift, which decides whether a downloaded Petal may be installed: a bundle signed as asked is
// accepted; one signed as something else, one changed after it was signed and one never signed are refused; and
// nothing signed ad hoc is ever Petal's maker's. It makes its own tiny bundles in the temporary folder and signs
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

    /// A bundle with a program and one resource, signed ad hoc under `identifier` (nil: left unsigned).
    static func bundle(_ name: String, in folder: URL, identifier: String?) -> URL {
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

        if failures > 0 { print("\(failures) update trust check(s) failed"); exit(1) }
        print("update trust: all checks passed")
    }
}
