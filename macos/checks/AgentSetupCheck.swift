import Foundation

// Checks AgentSetup.swift: taking back what Petal set up for other AI agents removes only Petal's own. On throwaway
// folders in the temporary folder: a real copy of Petal's skill goes; a skills folder that is a symbolic link, and
// what it points at, stay; a SKILL.md that is a link stays, and its target; a folder with anything else in it stays;
// a copy that differs from the skill Petal carries stays. The `petal` command goes only when it's a link into a
// Petal.app. A registration is Petal's only when it runs a Petal.app's executable with --mcp (Claude Code: in the
// user's scope). Run with macos/checks/run.sh.

@main
struct AgentSetupCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; print("FAIL: \(what)") }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) || AgentSetup.isLink(url.path) }

    static func main() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "petal-agentsetup-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let ours = Data("---\nname: petal\n---\nPetal's skill.\n".utf8)

        // A real copy Petal made: installed, then removed with its folder.
        let real = root.appending(path: "a/skills/petal")
        AgentSetup.installSkill(ours, in: real)
        expect((try? Data(contentsOf: real.appending(path: "SKILL.md"))) == ours, "the skill is installed into a new folder")
        expect(AgentSetup.removeSkill(ours, from: real) && !exists(real), "a real copy of Petal's skill goes, with its folder")

        // The skills folder is a link to the person's own folder: neither is touched, by removing or installing.
        let theirs = root.appending(path: "dev/petal-skill")
        try? fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        try? ours.write(to: theirs.appending(path: "SKILL.md"))
        let linked = root.appending(path: "b/skills/petal")
        try? fm.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: linked, withDestinationURL: theirs)
        expect(!AgentSetup.removeSkill(ours, from: linked), "a skills folder that is a link isn't removed")
        expect(AgentSetup.isLink(linked.path) && (try? Data(contentsOf: theirs.appending(path: "SKILL.md"))) == ours,
               "the link and the folder it points at both stay")
        let edited = Data("---\nname: petal\n---\nMy own version.\n".utf8)
        try? edited.write(to: theirs.appending(path: "SKILL.md"))
        AgentSetup.installSkill(ours, in: linked)
        expect((try? Data(contentsOf: theirs.appending(path: "SKILL.md"))) == edited, "installing never writes through a linked folder")

        // SKILL.md itself a link: it stays, and so does its target.
        let fileLink = root.appending(path: "c/skills/petal")
        try? fm.createDirectory(at: fileLink, withIntermediateDirectories: true)
        let target = root.appending(path: "dev/SKILL.md")
        try? ours.write(to: target)
        try? fm.createSymbolicLink(at: fileLink.appending(path: "SKILL.md"), withDestinationURL: target)
        expect(!AgentSetup.removeSkill(ours, from: fileLink) && AgentSetup.isLink(fileLink.appending(path: "SKILL.md").path) && exists(target),
               "a SKILL.md that is a link stays, and its target")
        AgentSetup.installSkill(Data("---\nname: petal\n---\nNewer.\n".utf8), in: fileLink)
        expect((try? Data(contentsOf: target)) == ours, "installing never writes through a linked SKILL.md")

        // A folder with anything else in it stays whole.
        let more = root.appending(path: "d/skills/petal")
        try? fm.createDirectory(at: more, withIntermediateDirectories: true)
        try? ours.write(to: more.appending(path: "SKILL.md"))
        try? Data("notes".utf8).write(to: more.appending(path: "notes.md"))
        expect(!AgentSetup.removeSkill(ours, from: more) && exists(more.appending(path: "SKILL.md")) && exists(more.appending(path: "notes.md")),
               "a folder with other contents stays")

        // A copy that isn't byte for byte the skill Petal carries stays.
        let differs = root.appending(path: "e/skills/petal")
        try? fm.createDirectory(at: differs, withIntermediateDirectories: true)
        try? edited.write(to: differs.appending(path: "SKILL.md"))
        expect(!AgentSetup.removeSkill(ours, from: differs) && exists(differs.appending(path: "SKILL.md")), "a skill that differs stays")
        // Someone else's skill by that name is never replaced.
        let other = root.appending(path: "f/skills/petal")
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        let someone = Data("---\nname: something-else\n---\n".utf8)
        try? someone.write(to: other.appending(path: "SKILL.md"))
        AgentSetup.installSkill(ours, in: other)
        expect((try? Data(contentsOf: other.appending(path: "SKILL.md"))) == someone, "someone else's skill isn't replaced")

        // The command: only a link into a Petal.app goes.
        let bin = root.appending(path: "bin")
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let petalLink = bin.appending(path: "petal")
        try? fm.createSymbolicLink(atPath: petalLink.path, withDestinationPath: "/Applications/Petal.app/Contents/MacOS/Petal")
        expect(AgentSetup.unlinkCommand(petalLink) && !exists(petalLink), "Petal's own command link goes")
        try? fm.createSymbolicLink(atPath: petalLink.path, withDestinationPath: "/usr/local/bin/something-else")
        expect(!AgentSetup.unlinkCommand(petalLink) && AgentSetup.isLink(petalLink.path), "a link to anything else stays")
        try? fm.removeItem(at: petalLink)
        try? Data("#!/bin/sh\n".utf8).write(to: petalLink)
        expect(!AgentSetup.unlinkCommand(petalLink) && exists(petalLink), "a file named petal stays")

        // The MCP registration, as each agent prints it.
        let claude = """
            petal:
              Scope: User config (available in all your projects)
              Status: ✔ Connected
              Type: stdio
              Command: /Applications/Petal.app/Contents/MacOS/Petal
              Args: --mcp
              Environment:
            """
        let codex = """
            petal
              enabled: true
              transport: stdio
              command: /Applications/Petal.app/Contents/MacOS/Petal
              args: --mcp
            """
        expect(AgentSetup.isPetalRegistration(claude, claude: true), "Claude Code's user registration of Petal is Petal's")
        expect(AgentSetup.isPetalRegistration(codex, claude: false), "Codex's registration of Petal is Petal's")
        expect(!AgentSetup.isPetalRegistration(claude.replacingOccurrences(of: "User config", with: "Project config"), claude: true),
               "a project's registration isn't the one Petal makes")
        expect(!AgentSetup.isPetalRegistration(codex.replacingOccurrences(of: "/Applications/Petal.app/Contents/MacOS/Petal", with: "/usr/local/bin/petal-server"), claude: false),
               "a registration running something else is someone else's")
        expect(!AgentSetup.isPetalRegistration(codex.replacingOccurrences(of: "args: --mcp", with: "args: --mcp --other"), claude: false),
               "a registration with other arguments is someone else's")
        expect(!AgentSetup.isPetalRegistration("No MCP server found with name: petal", claude: true), "no registration isn't Petal's")

        if failures > 0 { print("agent setup: \(failures) failed"); exit(1) }
        print("agent setup: only Petal's own skill copy, command link and registration are ever taken back; links are never followed")
    }
}
