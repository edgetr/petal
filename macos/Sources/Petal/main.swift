import AppKit

// `Petal --mcp`: Claude's Petal tools on stdin and stdout, started by the Claude panel's session.
if CommandLine.arguments.contains("--mcp") { MCP.run() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments

    // `petal <command>` (Petal's executable, linked as ~/.local/bin/petal): the dock from a shell.
    if arguments.count > 1 && CLI.commands.contains(arguments[1]) {
        app.setActivationPolicy(.prohibited)
        CLI.run(Array(arguments.dropFirst()))
    }
    // `Petal doctor` and `Petal report`: checking Petal, and telling its maker what went wrong.
    if arguments.count > 1 && (arguments[1] == "doctor" || arguments[1] == "report") {
        app.setActivationPolicy(.prohibited)
        Doctor.command(arguments)
    }
    // `Petal --restore-dock` gives macOS's Dock back without Petal running (bin/petal restore-dock).
    if arguments.contains("--restore-dock") {
        SystemDock.restore()
        exit(0)
    }
    if arguments.contains("--bench-dock") {
        app.setActivationPolicy(.prohibited)
        DockBench.run()
    }
    if arguments.contains("--bench") {
        app.setActivationPolicy(.prohibited)
        Bench.run()
    }
    if let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 1 {
        app.setActivationPolicy(.prohibited)
        Snapshot.run(to: arguments[index + 1])
        exit(0)
    }

    // One Petal at a time. A restart waits for the old one to finish giving the Dock back.
    let others = {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
    let deadline = Date().addingTimeInterval(5)
    while !others().isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    if !others().isEmpty { exit(0) }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
