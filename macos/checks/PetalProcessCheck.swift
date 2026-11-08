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

        // What main.swift starts each as: the same parser, so a process is a dock exactly when it starts as one.
        typealias L = PetalProcess.Launch
        let launches: [([String], L)] = [
            ([petal], .dock), ([petal, "-psn_0_1"], .dock), ([petal, "-NSDocumentRevisionsDebugMode", "YES"], .dock),
            ([petal, "--mcp"], .mcp), ([petal, "-psn_0_1", "--mcp"], .mcp),
            ([petal, "run", "--key", "x", "--", "x", "--mcp"], .command(["run", "--key", "x", "--", "x", "--mcp"])),
            ([petal, "mode", "social"], .command(["mode", "social"])), ([petal, "no-such-command"], .command(["no-such-command"])),
            ([petal, "-h"], .help), ([petal, "--help"], .help),
            ([petal, "--restore-dock"], .restoreDock),
            ([petal, "--snapshot", "/tmp/snap"], .snapshot("/tmp/snap")),
            ([petal, "--bench-windows-idle", "Settings: AI"], .benchWindowsIdle("Settings: AI")),
            ([petal, "--bench-windows-child", "settings"], .benchWindowsChild(settingsOnly: true)),
            ([petal, "--bench-windows-child"], .benchWindowsChild(settingsOnly: false)),
            ([petal, "--bench-windows", "--runs", "20", "--only", "Chat, 60 messages", "--json", "/tmp/a.json"], .benchWindows(settingsOnly: false)),
            ([petal, "--bench-settings"], .benchWindows(settingsOnly: true)),
            ([petal, "--bench-dock"], .benchDock), ([petal, "--bench-dock", "/tmp/strips"], .benchDock), ([petal, "--bench"], .bench),
            ([petal, "--routines-check", "--ai"], .routinesCheck(ai: true)), ([petal, "--routines-check"], .routinesCheck(ai: false)),
        ]
        for (argv, launch) in launches {
            let parsed = PetalProcess.parse(argv)
            expect(parsed == launch, "\(argv) starts as \(launch), parsed \(parsed)")
        }
        // Written wrong: its usage and a non-zero exit before a dock starts, so never a dock.
        let malformed: [[String]] = [
            [petal, "--snapshot"], [petal, "--snapshot", "--ai"], [petal, "--bench-windows-idle"],
            [petal, "--bench-windows-idle", "--runs"], [petal, "--bench-nope"], [petal, "--benchmark"], [petal, "-psn_0_1", "--bench-x"],
            [petal, "--bench-windows", "--runs"], [petal, "--bench-windows", "--runs", "many"], [petal, "--bench-settings", "--json"],
            [petal, "--bench-windows", "--only"],
        ]
        for argv in malformed {
            guard case .usage(let message) = PetalProcess.parse(argv) else { expect(false, "\(argv) is written wrong: \(PetalProcess.parse(argv))"); continue }
            expect(message.contains("usage: Petal --"), "\(argv) says how it's written: \(message)")
            expect(!PetalProcess.isDock(arguments: argv), "written wrong, not a dock: \(argv)")
        }

        // This process's own arguments, as sysctl gives them.
        let mine = PetalProcess.arguments(of: getpid())
        expect(mine == CommandLine.arguments, "own arguments read back: \(String(describing: mine)) vs \(CommandLine.arguments)")
        expect(PetalProcess.arguments(of: 999_999) == nil, "a process that doesn't exist has no arguments")
        expect(PetalProcess.isDock(pid: 999_999), "unreadable arguments count as a dock")

        // The Dock guard's test, with stand-ins for pgrep and ps: (each process's argv, whether a dock runs). The
        // same rules as isDock: a command, `petal run` above all (it lasts as long as what it runs), is never a dock.
        let spaced = "/Users/me/Petal Builds/Petal.app/Contents/MacOS/Petal"
        let cases: [([[String]], Bool)] = [
            ([], false),
            ([[petal]], true),
            ([[spaced]], true),
            ([[petal, "--bench-windows", "--runs", "20"], [petal, "--bench-windows-idle", "Chat, 60 messages"]], false),
            ([[petal, "--mcp"], [petal, "--snapshot", "/tmp/s"], [petal, "--routines-check"], [petal, "--restore-dock"]], false),
            ([[petal, "--bench-dock"], [petal, "-psn_0_1"]], true),
            ([[petal, "-NSDocumentRevisionsDebugMode", "YES"]], true),
            ([[petal, "mode", "social"]], false),
            ([[petal, "doctor"], [petal, "no-such-command"]], false),
            ([[petal, "run", "--key", "Anthropic", "--", "npm", "run", "dev"]], false),
            ([[spaced, "run", "--key", "x", "--stdin", "--", "sh", "-c", "sleep 3600"]], false),
            ([[petal, "run", "--", "env"], [spaced]], true),
            ([[petal, "-psn_0_1", "--mcp"]], false),
            ([[""]], true),                     // gone before ps read it: unsure, so running
            ([[petal, "--snapshot"]], false),   // written wrong: it ends before a dock starts
            ([[petal, "--bench-windows-idle"]], false),
            ([[petal, "--bench-nope"]], false),
            ([[petal, "-h"]], false),
            ([[petal, "-psn_0_1", "--help"]], true),
        ]
        for (processes, running) in cases {
            func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var script = "pgrep() { \(processes.isEmpty ? ":" : "echo " + processes.indices.map { String($0 + 1) }.joined(separator: " ")); }\n"
            script += "ps() { case \"$2 $4\" in " + processes.enumerated().map { process in
                let pid = process.offset + 1
                let program = process.element.first ?? ""
                let args = process.element.joined(separator: " ")
                return "\"comm= \(pid)\") printf '%s\\n' \(quoted(program)) ;; \"args= \(pid)\") printf '%s\\n' \(quoted(args)) ;;"
            }.joined(separator: " ")
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
            for argv in processes where argv != [""] {
                expect(PetalProcess.isDock(arguments: argv) == running || processes.count > 1, "guard and isDock agree on \(argv)")
            }
        }

        if failed > 0 { print("petal process: \(failed) failed"); exit(1) }
        print("petal process: all checks passed")
    }
}
