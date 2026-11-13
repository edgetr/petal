import Foundation

// Checks WhatsNew.swift: which versions' notes open by themselves when Petal starts (never on a first install, once
// per version, each version missed since the last one Petal ran as), and which part of a notes file the app shows.
// Pure: no file, no window. Run with macos/checks/run.sh.

@main
struct WhatsNewCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; print("FAIL: \(what)") }
    }

    static func main() {
        let carried = ["2.0.1", "2.1.0", "2.1.2", "2.1.3", "2.2.0", "2.3.0", "readme"]
        func shown(_ last: String?, _ running: String, welcomed: Bool = true) -> [String] {
            WhatsNew.versions(last: last, running: running, welcomed: welcomed, carried: carried)
        }

        // No record: welcomed is a Petal from before the record was kept, updated; not welcomed is a first install.
        expect(shown(nil, "2.2.0") == ["2.2.0"], "no record and welcomed shows the running version's notes")
        expect(shown(nil, "2.2.0", welcomed: false).isEmpty, "a first install shows nothing")
        expect(shown("2.1.3", "2.2.0", welcomed: false).isEmpty, "nothing shows while the welcome isn't done")
        // Once per version.
        expect(shown("2.2.0", "2.2.0").isEmpty, "the same version shows nothing")
        expect(shown("2.2", "2.2.0").isEmpty, "2.2 and 2.2.0 are one version")
        // Newer: each version missed, newest first.
        expect(shown("2.1.3", "2.2.0") == ["2.2.0"], "one version newer shows that one")
        expect(shown("2.1.0", "2.3.0") == ["2.3.0", "2.2.0", "2.1.3", "2.1.2"], "skipped versions each show, newest first")
        expect(shown("2.1.3", "2.4.0") == ["2.4.0", "2.3.0", "2.2.0"], "a version the app doesn't carry still shows first")
        expect(!shown("2.1.0", "2.2.0").contains("2.3.0"), "notes of a version after the running one never show")
        expect(!shown("2.1.0", "2.2.0").contains("2.1.0"), "the version Petal ran as before isn't shown again")
        // Older, and versions that aren't plain numbers.
        expect(shown("2.3.0", "2.2.0").isEmpty, "going back to an older version shows nothing")
        expect(shown("2.1.3", "dev").isEmpty, "a running version that isn't plain numbers shows nothing")
        expect(shown("2.1.3", "2.2.0-beta").isEmpty, "a running version with words shows nothing")
        expect(shown("garbage", "2.2.0") == ["2.2.0"], "a record that isn't a version counts as none")

        // What's kept as the last version.
        expect(WhatsNew.keeps(last: nil, running: "2.2.0"), "a first start keeps its version")
        expect(WhatsNew.keeps(last: "2.1.3", running: "2.2.0"), "an update keeps its version")
        expect(WhatsNew.keeps(last: "2.3.0", running: "2.2.0"), "going back keeps the older version")
        expect(!WhatsNew.keeps(last: "2.2.0", running: "2.2.0"), "the same version writes nothing")
        expect(!WhatsNew.keeps(last: "2.1.3", running: "dev"), "a version that isn't plain is never kept")
        expect(WhatsNew.keeps(last: "2.2.0-beta", running: "2.2.0"), "a record that isn't a plain version is replaced, even one that reads as this one")

        // What opens needs the version kept: a start that can't write state.json opens nothing, or it would open again
        // at every start.
        expect(WhatsNew.opens(["2.2.0"], kept: true) && !WhatsNew.opens(["2.2.0"], kept: false) && !WhatsNew.opens([], kept: true),
               "What's New opens only with something to show, once the version is kept")

        // Swept: thousands of Macs, each started many times as random versions (updates, going back, "2.1" beside
        // "2.1.0", builds that aren't plain numbers), the welcome finished at a random start, state.json sometimes
        // unwritable, as ReleaseNotes.afterLaunch does it.
        var random = SystemRandomNumberGenerator()
        let versionPool = ["2.0.1", "2.1", "2.1.0", "2.1.2", "2.1.3", "2.1.4", "2.2.0", "2.2", "2.3.0", "10.0", "dev", "2.2.0-beta", ""]
        var opened = 0
        for _ in 0..<3000 {
            var last: String? = Bool.random(using: &random) ? nil : versionPool.randomElement(using: &random)!
            let welcomedAt = Int.random(in: 0...4, using: &random)
            var shownSince: [String: Bool] = [:]   // a version shown, and whether an older one was kept since
            var previousKept = last
            for start in 0..<12 {
                let running = versionPool.randomElement(using: &random)!
                let welcomed = start >= welcomedAt
                let writable = Int.random(in: 0..<5, using: &random) > 0
                let versions = WhatsNew.versions(last: last, running: running, welcomed: welcomed, carried: carried)
                let kept = WhatsNew.keeps(last: last, running: running) && writable
                let opens = WhatsNew.opens(versions, kept: kept)
                let what = "start \(start): last \(last ?? "none") running \(running) welcomed \(welcomed) writable \(writable) -> \(versions)"
                if !versions.isEmpty {
                    expect(WhatsNew.keeps(last: last, running: running), "whatever would show is kept too: \(what)")
                    expect(welcomed && UpdateTrust.plainVersion(running) && versions[0] == running, "it shows the running version first, after the welcome: \(what)")
                    expect(versions.allSatisfy { UpdateTrust.plainVersion($0) && !UpdateTrust.newer($0, than: running) }, "never a version after the running one: \(what)")
                    if let last, UpdateTrust.plainVersion(last) {
                        expect(versions.allSatisfy { UpdateTrust.newer($0, than: last) }, "only versions after the one Petal ran as: \(what)")
                    }
                    expect(zip(versions, versions.dropFirst()).allSatisfy { UpdateTrust.newer($0, than: $1) }, "newest first, each once: \(what)")
                }
                if opens {
                    opened += 1
                    let key = shownSince.keys.first { WhatsNew.same($0, running) }
                    expect(key.map { shownSince[$0] == true } ?? true, "a version opens twice only after going back to an older one: \(what)")
                    if let key { shownSince[key] = nil }
                    shownSince[running] = false
                }
                if kept {
                    last = running
                    if let previousKept, UpdateTrust.plainVersion(previousKept), UpdateTrust.newer(previousKept, than: running) {
                        for (version, _) in shownSince where UpdateTrust.newer(version, than: running) { shownSince[version] = true }
                    }
                    previousKept = running
                }
                if failures > 20 { break }
            }
        }
        expect(opened > 0, "the sweep opened What's New at all")

        // Versions as UpdateTrust orders them: "2.1" and "2.1.0" one version, never newer than itself, and in one order.
        let plain = ["0", "1", "2", "2.1", "2.1.0", "2.1.0.0", "2.1.3", "2.1.10", "2.1.9", "2.10", "2.9.9", "10.0", "999999.1"]
        for a in plain {
            expect(!UpdateTrust.newer(a, than: a) && WhatsNew.same(a, a), "\(a) isn't newer than itself")
            for b in plain {
                expect(!(UpdateTrust.newer(a, than: b) && UpdateTrust.newer(b, than: a)), "\(a) and \(b) aren't each newer than the other")
                expect(UpdateTrust.newer(a, than: b) || UpdateTrust.newer(b, than: a) || WhatsNew.same(a, b), "\(a) and \(b) are in order")
                for c in plain where UpdateTrust.newer(a, than: b) && UpdateTrust.newer(b, than: c) {
                    expect(UpdateTrust.newer(a, than: c), "\(a) after \(b) after \(c)")
                }
            }
        }
        expect(UpdateTrust.newer("2.1.10", than: "2.1.9") && WhatsNew.same("2.1", "2.1.0.0"), "parts compare as numbers; missing parts are 0")

        // The part of a notes file the app shows.
        let file = """
            Petal checks who made an update.

            - Signed updates only.

            \(WhatsNew.releasePageOnly)
            Petal needs macOS 26 or later. Downloaded in a browser, it needs Open Anyway once.

            """
        let shownText = WhatsNew.inApp(file)
        expect(shownText == "Petal checks who made an update.\n\n- Signed updates only.", "the app leaves out the release page's part")
        expect(WhatsNew.inApp("A line.\r\n\r\n" + WhatsNew.releasePageOnly + "\r\nmacOS 26") == "A line.", "a marker on a CRLF line is found")
        expect(WhatsNew.inApp("Only the app's words.\n\n") == "Only the app's words.", "notes without the marker show whole")
        expect(WhatsNew.version(ofFile: "2.1.3.md") == "2.1.3", "a notes file names its version")
        expect(WhatsNew.version(ofFile: "README.md") == nil && WhatsNew.version(ofFile: "2.1.3.txt") == nil
                   && WhatsNew.version(ofFile: "../2.1.md") == nil, "other files in the folder aren't notes")

        // Every notes file in the repository marks where the release page's own part starts, at most once.
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "notes")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        expect(!names.isEmpty, "the notes folder has notes")
        for name in names where name.hasSuffix(".md") {
            expect(WhatsNew.version(ofFile: name) != nil, "\(name) is named by a plain version")
            let text = (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? ""
            let marks = text.components(separatedBy: WhatsNew.releasePageOnly).count - 1
            expect(marks <= 1, "\(name) marks the release page's part once at most")
            expect(!WhatsNew.inApp(text).isEmpty, "\(name) has words for the app")
            expect(!WhatsNew.inApp(text).contains("Open Anyway"), "\(name) leaves Open Anyway to the release page")
        }

        if failures > 0 { print("what's new: \(failures) failed"); exit(1) }
        print("what's new: opens once after an update with each version missed, never on a first install; the release page's own lines stay there")
    }
}
