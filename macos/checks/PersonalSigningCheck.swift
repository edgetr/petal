import Foundation

// Checks PersonalSigning.swift: the keychain Petal signs the person's own builds with is unlocked only while one
// build is signed, locked again on every way out, and set to lock by itself. It runs no `security` command and
// touches no keychain: the commands are only written down. Run with macos/checks/run.sh.
@main
struct PersonalSigningCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    struct Stopped: Error {}

    static func main() {
        let keychain = "/tmp/check/petal-personal.keychain-db"
        var ran: [[String]] = []
        let run = { (tool: String, arguments: [String]) in ran.append([tool] + arguments) }
        let lock = ["/usr/bin/security", "lock-keychain", keychain]
        let unlock = ["/usr/bin/security", "unlock-keychain", "-p", "secret", keychain]

        // A build signed: unlocked first, locked last, the signing in between.
        let answer = PersonalSigning.unlocked(keychain, password: "secret", run: run) { () -> String in
            ran.append(["codesign"])
            return "signed"
        }
        expect(answer == "signed", "the signing's own answer comes back")
        expect(ran.first == unlock, "the keychain is unlocked first", "\(ran)")
        expect(ran.last == lock, "and locked again once the build is signed", "\(ran)")
        let signedAt = ran.firstIndex(of: ["codesign"]) ?? -1, lockedAt = ran.lastIndex(of: lock) ?? -1
        expect(signedAt > 0 && lockedAt > signedAt && ran.filter { $0 == lock }.count == 1, "the lock comes after the signing, once", "\(ran)")
        expect(ran.dropFirst(lockedAt + 1).isEmpty, "nothing uses the keychain after it's locked")

        // Signing that fails: locked all the same.
        ran = []
        var threw = false
        do {
            try PersonalSigning.unlocked(keychain, password: "secret", run: run) { () throws -> Void in
                ran.append(["codesign"])
                throw Stopped()
            }
        } catch { threw = true }
        expect(threw && ran.last == lock, "signing that fails still locks the keychain", "\(ran)")

        // An identity that isn't found (nothing is signed): locked all the same.
        ran = []
        threw = false
        do { try PersonalSigning.unlocked(keychain, password: "secret", run: run) { () throws -> Void in throw Stopped() } } catch { threw = true }
        expect(threw && ran.first == unlock && ran.last == lock, "a keychain opened for nothing is locked again", "\(ran)")

        // It locks by itself too: when the Mac sleeps, and after a short while without use.
        let settings = PersonalSigning.settings(keychain)
        expect(settings.first == "set-keychain-settings" && settings.last == keychain, "the settings are this keychain's", "\(settings)")
        expect(settings.contains("-l") && settings.contains("-u"), "it locks when the Mac sleeps and after a while without use", "\(settings)")
        let seconds = settings.firstIndex(of: "-t").flatMap { $0 + 1 < settings.count ? Int(settings[$0 + 1]) : nil } ?? 0
        expect((1...120).contains(seconds), "the while is a short one", "\(settings)")
        ran = []
        PersonalSigning.unlocked(keychain, password: "secret", run: run) {}
        expect(ran.contains(["/usr/bin/security"] + settings), "an older keychain is given that setting when it's unlocked", "\(ran)")

        // Making it: the same settings from the start, the key for codesign alone.
        let made = PersonalSigning.make(keychain, password: "secret", identity: "/tmp/check/id.p12")
        expect(made.first?.first == "create-keychain" && made.contains(settings), "a new keychain locks by itself from the start", "\(made)")
        let imported = made.first { $0.first == "import" } ?? []
        expect(imported.contains("/tmp/check/id.p12") && Array(imported.suffix(2)) == ["-T", "/usr/bin/codesign"], "the identity goes in for codesign alone", "\(imported)")
        expect(made.allSatisfy { $0.contains(keychain) }, "every step names this keychain, never another", "\(made)")
        expect(PersonalSigning.lock(keychain) == ["lock-keychain", keychain], "locking names this keychain, never all of them")

        print("personal signing: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
