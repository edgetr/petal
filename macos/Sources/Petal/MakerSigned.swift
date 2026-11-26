import Foundation
import Security

/// A program on disk is the one its maker signed (checked by checks/MakerSignedCheck.swift): a Mach-O program, never a
/// script (an interpreter runs whatever the script says, and anyone can write one), whose signature is valid now and
/// comes from Apple's chain to that maker's Team ID, with one of the identifiers the maker gives it. Petal runs only
/// such a program from `claudePath` or `codexPath` as its AI, with the person's API key and as its own chat.
enum MakerSigned {
    /// The code requirement for `team` and `identifiers`; nil when either couldn't be written into one safely.
    static func requirement(team: String, identifiers: [String]) -> String? {
        let plain = { (text: String) in !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") } }
        guard plain(team), !identifiers.isEmpty, identifiers.allSatisfy(plain) else { return nil }
        let named = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(named))"
    }

    /// The file starts as a Mach-O program does (thin or universal, either byte order).
    static func isProgram(_ head: Data) -> Bool {
        guard head.count >= 4 else { return false }
        let magic = head.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic)
    }

    /// The program at `path` (links already followed) is signed so, its signature checked now.
    static func check(_ path: String, team: String, identifiers: [String]) -> Bool {
        guard let text = requirement(team: team, identifiers: identifiers),
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        try? handle.close()
        guard isProgram(head) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
