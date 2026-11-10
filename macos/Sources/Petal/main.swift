import AppKit

// Started through a link (~/.local/bin/petal): run again as the app itself, so Bundle.main is Petal.app (its
// Info.plist, tools and id) rather than the folder the link is in.
// (The path macOS ran, not Bundle.main's idea of it: through a link Bundle.main may have no executable at all.)
var executableSize: UInt32 = 0
_NSGetExecutablePath(nil, &executableSize)
var executableBuffer = [CChar](repeating: 0, count: Int(executableSize) + 1)
if _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 {
    let path = String(cString: executableBuffer)
    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    if real != URL(fileURLWithPath: path).standardizedFileURL.path {
        // argv[0] too: macOS finds the main bundle from it.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(real)] + CommandLine.arguments.dropFirst().map { strdup($0) } + [nil]
        execv(real, &argv)   // returns only if it couldn't
    }
}

// What this process is (PetalProcess.parse, the same parser that tells a dock from the rest): a tool written wrong
// says how it's written and ends here, before anything starts.
let launch = PetalProcess.parse(CommandLine.arguments)
if case .usage(let message) = launch {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

// `Petal --mcp`: Claude's Petal tools on stdin and stdout, started by the Claude panel's session. (Not a command
// `petal run` starts that has --mcp among its own words.)
if launch == .mcp { MCP.run() }

MainActor.assumeIsolated {
    let app = NSApplication.shared

    switch launch {
    case .command(let words):
        // `petal <command>` (Petal's executable, linked as ~/.local/bin/petal): the dock from a shell.
        if CLI.commands.contains(words[0]) {
            app.setActivationPolicy(.prohibited)
            CLI.run(words)
        }
        // `Petal doctor` and `Petal report`: checking Petal, and telling its maker what went wrong.
        if words[0] == "doctor" || words[0] == "report" {
            app.setActivationPolicy(.prohibited)
            Doctor.command(CommandLine.arguments)
        }
        // Anything else typed after `petal` is a command it doesn't know: say so, rather than start a second dock.
        FileHandle.standardError.write(Data("petal: no command \"\(words[0])\". These are the ones there are:\n\n\(CLI.help)\n".utf8))
        exit(1)
    case .help:
        print(CLI.help)
        exit(0)
    case .restoreDock:
        // `Petal --restore-dock` gives macOS's Dock back without Petal running (`petal restore-dock`).
        SystemDock.restore()
        exit(0)
    case .benchWindowsIdle(let name):
        // Petal's windows, timed headless on a copy of the settings (SettingsBench.swift).
        app.setActivationPolicy(.prohibited)
        SettingsBench.isolate()
        WindowBench.idle(name)
    case .benchWindowsChild(let settingsOnly):
        app.setActivationPolicy(.prohibited)
        SettingsBench.isolate()
        WindowBench.child(settingsOnly: settingsOnly)
    case .benchWindows(let settingsOnly):
        app.setActivationPolicy(.prohibited)
        SettingsBench.isolate()
        WindowBench.run(CommandLine.arguments, settingsOnly: settingsOnly)
    case .benchNotes:
        // Its own throwaway folders, set before anything reads a setting (never a copy of the person's).
        app.setActivationPolicy(.prohibited)
        NotesBench.run(CommandLine.arguments)
    case .benchDock:
        app.setActivationPolicy(.prohibited)
        SettingsBench.isolate()
        DockBench.run()
    case .bench:
        app.setActivationPolicy(.prohibited)
        Bench.run()
    case .routinesCheck(let ai):
        app.setActivationPolicy(.prohibited)
        RoutinesCheck.run(ai: ai)
    case .snapshot(let folder):
        app.setActivationPolicy(.prohibited)
        SettingsBench.isolate()
        Snapshot.run(to: folder)
        SettingsBench.cleanUp()
        exit(0)
    case .viewerCheck:
        // Its own throwaway folders, set before anything reads a setting (never a copy of the person's).
        app.setActivationPolicy(.prohibited)
        ViewerCheck.isolate()
        ViewerCheck.run(CommandLine.arguments)
    case .helpersCheck(let ai):
        // Its own throwaway folders, set before anything reads a setting (never a copy of the person's).
        app.setActivationPolicy(.prohibited)
        HelpersCheck.run(ai: ai)
    case .displayCheck(let folder):
        // One real hidden display, for whoever is at the Mac (it changes the screens for a few seconds).
        app.setActivationPolicy(.prohibited)
        DisplayCheck.run(folder: folder)
    case .browserCheck(let live):
        // A run's own browser, driven for real: headless on its own throwaway folders, or (--live) on a real hidden
        // display with a real browser, for whoever is at the Mac.
        app.setActivationPolicy(.prohibited)
        BrowserCheck.run(live: live)
    case .mcp, .usage:
        exit(0)   // handled above
    case .dock:
        break
    }

    // One Petal at a time. A restart waits for the old one to finish giving the Dock back. Only docks count: the AI's
    // tools, a command, a benchmark or a snapshot run alongside it (PetalProcess).
    let others = {
        NSRunningApplication.runningApplications(withBundleIdentifier: "tech.edgetr.petal")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && PetalProcess.isDock(pid: $0.processIdentifier) }
    }
    let deadline = Date().addingTimeInterval(5)
    while !others().isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    if !others().isEmpty { exit(0) }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // The standard editing keys for every text view, through a main menu that's never shown (EditMenu).
    app.mainMenu = EditMenu.make()
    app.run()
}
