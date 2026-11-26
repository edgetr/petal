import Foundation

// Checks MakerSigned.swift: Petal runs a program from claudePath or codexPath only when it's that app as its maker
// signed it. A script, a program signed ad hoc or by someone else (Apple's own `ls`), and one copied from Claude Code
// and changed are refused; Claude Code or Codex on this Mac, when there is one, is taken. Run with macos/checks/run.sh;
// it writes only in a throwaway folder.
@main
struct MakerSignedCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static let claude = (team: "Q6L2SF6YDW", identifiers: ["com.anthropic.claude-code"])
    static let codex = (team: "2DC432GLL2", identifiers: ["codex"])

    static func main() {
        // The requirement.
        expect(MakerSigned.requirement(team: "Q6L2SF6YDW", identifiers: ["com.anthropic.claude-code"])
               == "anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\" and (identifier \"com.anthropic.claude-code\")",
               "the requirement names Apple's chain, the maker's Team ID and the identifier")
        expect(MakerSigned.requirement(team: "2DC432GLL2", identifiers: ["codex", "codex-exec-server"])?.hasSuffix("(identifier \"codex\" or identifier \"codex-exec-server\")") == true,
               "several identifiers: any one of them")
        expect(MakerSigned.requirement(team: "X\" or anchor apple", identifiers: ["codex"]) == nil
               && MakerSigned.requirement(team: "2DC432GLL2", identifiers: ["codex\") or (true"]) == nil
               && MakerSigned.requirement(team: "", identifiers: ["codex"]) == nil && MakerSigned.requirement(team: "2DC432GLL2", identifiers: []) == nil,
               "nothing that could change the requirement's meaning is written into it")

        // What a program looks like.
        let bytes = { (values: [UInt8]) in Data(values) }
        expect(MakerSigned.isProgram(bytes([0xcf, 0xfa, 0xed, 0xfe])) && MakerSigned.isProgram(bytes([0xca, 0xfe, 0xba, 0xbe])),
               "a 64-bit program and a universal one are programs")
        expect(!MakerSigned.isProgram(Data("#!/bin/sh\n".utf8)) && !MakerSigned.isProgram(Data("#!".utf8)) && !MakerSigned.isProgram(Data()),
               "a script, or a file too short, isn't")

        let folder = FileManager.default.temporaryDirectory.appending(path: "petal-maker-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ tool: String, _ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }

        // A script that says it's Claude Code.
        let script = folder.appending(path: "claude").path
        FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\nexec /bin/sh -c 'echo $ANTHROPIC_API_KEY'\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        expect(!MakerSigned.check(script, team: claude.team, identifiers: claude.identifiers), "a script is never Claude Code")
        // Apple's own program, signed but not by the maker.
        expect(!MakerSigned.check("/bin/ls", team: claude.team, identifiers: claude.identifiers), "a program signed by someone else isn't")
        // A program signed ad hoc with Claude Code's identifier.
        let adHoc = folder.appending(path: "codex").path
        if (try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: adHoc)) != nil,
           run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "codex", adHoc]) == 0 {
            expect(!MakerSigned.check(adHoc, team: codex.team, identifiers: codex.identifiers), "a program signed ad hoc as codex isn't Codex")
        } else {
            expect(false, "the ad hoc program could be made")
        }
        expect(!MakerSigned.check(folder.appending(path: "nothing").path, team: codex.team, identifiers: codex.identifiers), "nothing there is nothing")

        // The real ones on this Mac, if there are: taken; and a copy changed by a byte isn't.
        for (name, maker) in [("claude", claude), ("codex", codex)] {
            let home = NSHomeDirectory()
            let places = name == "claude"
                ? ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                : ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            guard let real = places.compactMap({ path -> String? in
                guard let resolved = realpath(path, nil) else { return nil }
                defer { free(resolved) }
                return String(cString: resolved)
            }).first(where: { path in
                (FileHandle(forReadingAtPath: path).flatMap { try? $0.read(upToCount: 4) }).map(MakerSigned.isProgram) == true
            }) else {
                print("maker signed: no \(name) program on this Mac to check against")
                continue
            }
            expect(MakerSigned.check(real, team: maker.team, identifiers: maker.identifiers), "\(name) as its maker signed it is taken", real)
            expect(!MakerSigned.check(real, team: name == "claude" ? codex.team : claude.team, identifiers: name == "claude" ? codex.identifiers : claude.identifiers),
                   "\(name) isn't the other app")
            let changed = folder.appending(path: "\(name)-changed").path
            if (try? FileManager.default.copyItem(atPath: real, toPath: changed)) != nil, let handle = FileHandle(forUpdatingAtPath: changed) {
                let end = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: end / 2)
                let byte = (try? handle.read(upToCount: 1))?.first ?? 0
                try? handle.seek(toOffset: end / 2)
                try? handle.write(contentsOf: Data([byte ^ 0xff]))
                try? handle.close()
                expect(!MakerSigned.check(changed, team: maker.team, identifiers: maker.identifiers), "a copy of \(name) changed by a byte isn't \(name)")
            }
        }

        print("maker signed: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
