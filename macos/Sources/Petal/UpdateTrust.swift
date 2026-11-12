import Foundation
import Security

/// Whether a Petal that was downloaded is Petal's maker's. A checksum beside the download only says the download
/// arrived whole: both come from the same release, so whoever could replace one could replace the other. The
/// signature is what a release can't fake: every one is signed with Petal's own certificate, "Petal (Edgetr)",
/// whose key is not in the repository. An update, or a release put back by `petal personal reset`, is installed
/// only when it is signed with that certificate, whole, in every architecture; and an update rebuilt with the
/// person's own changes takes its source from the commit such a release says it was built from. It doesn't matter
/// how the running Petal is signed (a personal build has the person's own certificate): what's trusted is the
/// maker's, by its hash.
enum UpdateTrust {
    /// What every release satisfies: Petal's identifier, signed by the certificate with this hash (self-made, so
    /// it is its own root). `get.sh` and the release workflow check the same words (`macos/checks/run.sh` holds
    /// the three together). The certificate is never replaced: a release signed with another would be refused by
    /// every Petal already installed.
    static let maker = #"identifier "tech.edgetr.petal" and certificate root = H"29feb33bdddb5686cbc597ca9706b0b8a6f3b36d""#

    /// A version as a release's manifest says it: numbers with dots between them ("2.1.4"), nothing else. Anything
    /// else is refused before it's used, so a manifest can't name a folder on the disk or another download with it.
    static func plainVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy { part in
            (1...6).contains(part.count) && part.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// Whether version `a` comes after `b` ("2.1.10" after "2.1.9"; a missing part counts as 0).
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// A bundle's own Info.plist.
    private static func info(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// The version a bundle says it is (its CFBundleShortVersionString), read from its own Info.plist.
    static func version(of app: URL) -> String? {
        info(of: app)?["CFBundleShortVersionString"] as? String
    }

    /// A commit as git names it whole: 40 lowercase hex characters, nothing else.
    static func plainCommit(_ commit: String) -> Bool {
        let hex = commit.unicodeScalars
        return hex.count == 40 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// The commit a bundle says it was built from (build.sh writes it into Info.plist as PetalSourceCommit).
    static func commit(of app: URL) -> String? {
        info(of: app)?["PetalSourceCommit"] as? String
    }

    /// The source an update is rebuilt from when the person has changes of their own to Petal's code: the commit
    /// the release's own Petal.app says it was built from, and only when that app is what an update may install
    /// (`update`: the maker's, whole, the version its release said, newer than the one running). So what's built
    /// with the person's changes is the source of a release Petal's maker signed, never one a release only names.
    static func source(of app: URL, is version: String, over running: String, as requirement: String = maker) -> String? {
        guard update(app, is: version, over: running, as: requirement), let commit = commit(of: app), plainCommit(commit) else { return nil }
        return commit
    }

    /// The app at `app` is Petal's maker's, whole, and is the very version its release said (`version`): a release
    /// can't hand over another of the maker's builds, an older one, under a newer number.
    static func release(_ app: URL, is version: String, as requirement: String = maker) -> Bool {
        plainVersion(version) && signed(app, as: requirement) && self.version(of: app) == version
    }

    /// What an update may install over the Petal running now (`running`): the maker's build of the version its release
    /// said, and newer than the one running, so an update never takes Petal back to an older version.
    static func update(_ app: URL, is version: String, over running: String, as requirement: String = maker) -> Bool {
        newer(version, than: running) && release(app, is: version, as: requirement)
    }

    /// Puts a checked update (`app`) in place of the Petal at `place`, then looks at what is there now: true only
    /// when the bundle in place is itself what an update may install (`update`). What was checked a moment before,
    /// in the folder it was unpacked into, isn't taken for what was put in place.
    static func install(_ app: URL, in place: URL, is version: String, over running: String, as requirement: String = maker) throws -> Bool {
        _ = try FileManager.default.replaceItemAt(place, withItemAt: app)
        return update(place, is: version, over: running, as: requirement)
    }

    /// The app at `app` is validly signed, nothing in it changed since, and its signature meets `requirement`.
    static func signed(_ app: URL, as requirement: String = maker) -> Bool {
        var wanted: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &wanted) == errSecSuccess, let wanted else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, wanted) == errSecSuccess
    }
}
