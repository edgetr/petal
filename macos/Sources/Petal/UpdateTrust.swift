import Foundation
import Security

/// Whether a Petal that was downloaded is Petal's maker's. A checksum beside the download only says the download
/// arrived whole: both come from the same release, so whoever could replace one could replace the other. The
/// signature is what a release can't fake: every one is signed with Petal's own certificate, "Petal (Edgetr)",
/// whose key is not in the repository. An update, or a release put back by `petal personal reset`, is installed
/// only when it is signed with that certificate, whole, in every architecture. It doesn't matter how the running
/// Petal is signed (a personal build has the person's own certificate): what's trusted is the maker's, by its hash.
enum UpdateTrust {
    /// What every release satisfies: Petal's identifier, signed by the certificate with this hash (self-made, so
    /// it is its own root). `get.sh` and the release workflow check the same words (`macos/checks/run.sh` holds
    /// the three together). The certificate is never replaced: a release signed with another would be refused by
    /// every Petal already installed.
    static let maker = #"identifier "tech.edgetr.petal" and certificate root = H"29feb33bdddb5686cbc597ca9706b0b8a6f3b36d""#

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
