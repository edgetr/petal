import Foundation

/// Which Petal processes count as a dock (PetalProcess): the launch check, doctor and the Dock guard must never take a
/// benchmark, a snapshot, the AI's tools or a command for a second dock. Never looks at a real Petal: the guard's shell
/// test runs with `pgrep` and `ps` stood in for.
@main
struct PetalProcessCheck {
    static var failed = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition { failed += 1; print("FAIL: \(what)") }
    }

    static func main() {
        let petal = "/Applications/Petal.app/Contents/MacOS/Petal"
        let docks: [[String]] = [
            [petal], [petal, "-psn_0_12345"], [petal, "-NSDocumentRevisionsDebugMode", "YES"],
            ["/Users/me/petal/macos/build/Petal.app/Contents/MacOS/Petal"],
        ]
        for argv in docks { expect(PetalProcess.isDock(arguments: argv), "a dock: \(argv)") }
        let others: [[String]] = [
            [petal, "--mcp"], [petal, "--bench"], [petal, "--bench-dock"], [petal, "--bench-settings"],
            [petal, "--bench-windows", "--runs", "20", "--only", "Chat, 60 messages", "--json", "/tmp/a.json"],
            [petal, "--bench-windows-child", "settings"], [petal, "--bench-windows-idle", "Chat, 60 messages"],
            [petal, "--snapshot", "/tmp/snap"], [petal, "--routines-check", "--ai"], [petal, "--restore-dock"],
            [petal, "mode", "social"], [petal, "doctor"], [petal, "report"], [petal, "run", "--key", "x", "--", "env"],
            [petal, "no-such-command"], [petal, "-psn_0_1", "--mcp"],
        ]
        for argv in others { expect(!PetalProcess.isDock(arguments: argv), "not a dock: \(argv)") }

        // This process's own arguments, as sysctl gives them.
        let mine = PetalProcess.arguments(of: getpid())
        expect(mine == CommandLine.arguments, "own arguments read back: \(String(describing: mine)) vs \(CommandLine.arguments)")
        expect(PetalProcess.arguments(of: 999_999) == nil, "a process that doesn't exist has no arguments")
        expect(PetalProcess.isDock(pid: 999_999), "unreadable arguments count as a dock")

        // The Dock guard's test, with stand-ins for pgrep and ps: (the processes' arguments, whether a dock runs).
        let cases: [([String], Bool)] = [
            ([], false),
            (["\(petal)"], true),
            (["\(petal) --bench-windows --runs 20", "\(petal) --bench-windows-idle Chat, 60 messages"], false),
            (["\(petal) --mcp", "\(petal) --snapshot /tmp/s", "\(petal) --routines-check", "\(petal) --restore-dock"], false),
            (["\(petal) --bench-dock", "\(petal) -psn_0_1"], true),
            (["\(petal) mode social"], true),   // a command counts there: the guard leaves the Dock alone when unsure
            ([""], true),                       // gone before ps read it: unsure, so running
        ]
        for (processes, running) in cases {
            var script = "pgrep() { \(processes.isEmpty ? ":" : "echo " + processes.indices.map { String($0 + 1) }.joined(separator: " ")); }\n"
            script += "ps() { case \"$4\" in " + processes.enumerated().map { "\($0.offset + 1)) printf '%s\\n' '\($0.element)' ;;" }.joined(separator: " ")
            script += " *) ;; esac; }\n"
            script += PetalProcess.shellDockRunning + "\nif petal_dock; then echo yes; else echo no; fi\n"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == (running ? "yes" : "no"), "guard with \(processes): \(out)")
        }

        if failed > 0 { print("petal process: \(failed) failed"); exit(1) }
        print("petal process: all checks passed")
    }
}
