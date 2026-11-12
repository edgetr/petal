import Foundation

/// The keychain Petal signs the person's own builds with ("Petal (Personal)", Personal.swift), as rules without
/// AppKit (checked by checks/PersonalSigningCheck.swift): the `security` commands that make it, open it and close it.
/// It is open only while one build is signed: locked again on every way out of the signing, and by itself after two
/// minutes without use or when the Mac sleeps (should Petal be stopped halfway), so its key is never left ready to
/// sign between builds.
enum PersonalSigning {
    static let security = "/usr/bin/security"
    /// Seconds without use before the keychain locks by itself.
    static let idle = 120

    /// It locks by itself: when the Mac sleeps, and after `idle` seconds without use.
    static func settings(_ keychain: String) -> [String] { ["set-keychain-settings", "-l", "-u", "-t", String(idle), keychain] }
    static func unlock(_ keychain: String, password: String) -> [String] { ["unlock-keychain", "-p", password, keychain] }
    static func lock(_ keychain: String) -> [String] { ["lock-keychain", keychain] }

    /// What makes the keychain and puts the identity (a .p12 at `identity`) in it, for codesign alone to use.
    static func make(_ keychain: String, password: String, identity: String) -> [[String]] {
        [["create-keychain", "-p", password, keychain],
         settings(keychain),
         unlock(keychain, password: password),
         ["import", identity, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"],
         ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain]]
    }

    /// Does `body` with the keychain unlocked, and locks it again on every way out: `body` done, or `body` throwing.
    /// `run` runs one command. A keychain made before it locked by itself is given that setting here too.
    static func unlocked<T>(_ keychain: String, password: String, run: (String, [String]) -> Void, _ body: () throws -> T) rethrows -> T {
        defer { run(security, lock(keychain)) }
        run(security, unlock(keychain, password: password))
        run(security, settings(keychain))
        return try body()
    }
}
