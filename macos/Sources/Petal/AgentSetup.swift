import CryptoKit
import Foundation

/// What Petal sets up for the person's other AI agents (`OtherAgents`), and how it takes it back, as rules on files
/// and text that a check runs on throwaway folders (`macos/checks/run.sh`). Taking back only ever removes what is
/// Petal's own: a symbolic link is never followed, and anything that differs from what Petal put there is left
/// exactly as it is.
enum AgentSetup {
    /// Petal's executable inside an app bundle: what Petal's command link and its MCP registration point at.
    static let executableSuffix = "Petal.app/Contents/MacOS/Petal"

    /// Whether `path` is the item itself a symbolic link (never what it points at).
    static func isLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    // MARK: The skill

    /// Puts Petal's skill (`ours`) in `folder` (…/skills/petal/SKILL.md), or brings an older copy of it up to date.
    /// Left alone: a folder or SKILL.md that is a symbolic link (someone developing the skill keeps it elsewhere), and
    /// a SKILL.md that isn't Petal's.
    static func installSkill(_ ours: Data, in folder: URL) {
        let target = folder.appending(path: "SKILL.md")
        guard !isLink(folder.path), !isLink(target.path) else { return }
        if let existing = try? Data(contentsOf: target) {
            if existing == ours { return }
            guard String(decoding: existing, as: UTF8.self).contains("name: petal") else { return }   // someone else's
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? ours.write(to: target, options: .atomic)
    }

    /// The SHA-256 of each SKILL.md an earlier release copied into the agents' skills folders (1.0.0, 2.0.1, 2.1.0,
    /// and 2.1.2 and 2.1.3's, the same): a copy left by an older Petal is Petal's own too, so turning other agents
    /// off takes it back. `macos/checks/run.sh` checks every released tag's skill is here; a release that changes
    /// the skill adds the one it replaced.
    static let earlierSkills: Set<String> = [
        "fe2fdab59f5d401696922b4c796c7f1f9b0a1c46c7d40905acfe654a92025043",
        "5d87b4bbcdbc89f2617be9d9dc5ea60d67333eca5266147b48df42b819642ad1",
        "3c2ff5608f23e1b184cbb5020c41b6bd1d5846554c9f557ae9f1df9fd80cbc59",
        "99c90f0eee89b6f1e0fd511ae2e991aa130a004823ce1b39ab311e5ad28d9eba",
    ]

    /// SKILL.md's bytes as `earlierSkills` names them.
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Takes Petal's skill out of `folder`, and the folder with it: only a real folder (not a link) holding nothing
    /// but a real SKILL.md with exactly the bytes Petal carries (`ours`), or those of a copy an earlier release left
    /// (`earlier`, by their SHA-256). Anything else stays as it is. True when it was removed.
    @discardableResult
    static func removeSkill(_ ours: Data, from folder: URL, earlier: Set<String> = earlierSkills) -> Bool {
        let target = folder.appending(path: "SKILL.md")
        var directory: ObjCBool = false
        guard !isLink(folder.path), !isLink(target.path),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["SKILL.md"],
              let there = try? Data(contentsOf: target), there == ours || earlier.contains(digest(there)) else { return false }
        return (try? FileManager.default.removeItem(at: folder)) != nil
    }

    // MARK: The command

    /// Removes `link` (~/.local/bin/petal) only when it is itself a symbolic link that points into a Petal.app. A
    /// file, a folder or a link to anything else stays. True when it was removed.
    @discardableResult
    static func unlinkCommand(_ link: URL) -> Bool {
        guard isLink(link.path), let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
              destination.hasSuffix(executableSuffix) else { return false }
        return (try? FileManager.default.removeItem(at: link)) != nil
    }

    // MARK: The MCP registration

    /// Whether what `<agent> mcp get petal` printed is Petal's own registration, the one Petal makes: its command a
    /// Petal.app's executable and its only argument `--mcp`; with Claude Code, in the user's own scope (the one
    /// `mcp remove -s user` takes out). Anything else named `petal` is someone else's.
    static func isPetalRegistration(_ output: String, claude: Bool) -> Bool {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = text[..<colon].lowercased(), value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let command = fields["command"], command.hasSuffix(executableSuffix), fields["args"] == "--mcp" else { return false }
        return !claude || fields["scope"]?.lowercased().hasPrefix("user") == true
    }
}
