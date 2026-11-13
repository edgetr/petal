import Darwin
import Foundation

/// Which of the processes running Petal's code is a dock. They all share Petal's bundle id and name: the dock, but
/// also `Petal --mcp` (the AI's tools), `petal <command>` from a shell, the benchmarks, snapshots and checks. Only a
/// dock counts as "Petal running": the one-at-a-time check at launch, `petal doctor` and the Dock guard.
///
/// A dock is started with no arguments, or with macOS's own (`-psn_…`, `-NSDocumentRevisionsDebugMode YES`: one
/// dash). Anything with two dashes is a tool's flag, and never a dock, whether this Petal knows the flag or not: a
/// newer Petal's check run beside an older installed one (which has never heard of its flag) must not be taken for a
/// second dock by it, or the installed one quits at its next start.
enum PetalProcess {
    /// Flags that start Petal as something other than a dock (main.swift handles each before the dock starts).
    static let notDockFlags: Set<String> = ["--snapshot", "--routines-check", "--viewer-check", "--helpers-check", "--display-check", "--browser-check", "--look-check", "--mcp", "--restore-dock"]
    /// Every benchmark: --bench, --bench-dock, --bench-settings, --bench-windows, --bench-windows-child, -idle, --bench-notes.
    static let benchPrefix = "--bench"

    /// What a process started with these arguments (argv, its first being the program) does: main.swift starts it as
    /// this, and only `.dock` is a dock. One parser for both, so a process is never told apart differently from how
    /// it started.
    enum Launch: Equatable {
        /// `Petal --mcp`: the AI's tools on stdin and stdout.
        case mcp
        /// A first word that isn't a flag: `petal <command>`, `doctor`, `report`, or one Petal doesn't know.
        case command([String])
        case help
        case restoreDock
        case benchWindowsIdle(String)
        case benchWindowsChild(settingsOnly: Bool)
        case benchWindows(settingsOnly: Bool)
        case benchDock
        case bench
        /// `Petal --bench-notes [--json <file>]`: Petal Notes with many notes, timed headless on folders of its own.
        case benchNotes
        case routinesCheck(ai: Bool)
        case snapshot(String)
        /// `Petal --viewer-check [<file>…]`: the viewer's loading, headless, on throwaway files (its own, given none).
        case viewerCheck
        /// `Petal --helpers-check [--ai]`: helpers in notes run end to end, headless, on throwaway folders.
        case helpersCheck(ai: Bool)
        /// `Petal --display-check <folder> [--full]`: makes one real hidden display and puts a TextEdit window on it;
        /// with `--full`, three runs on two displays with TextEdit and Calculator (DisplayCheck.swift, which reads
        /// `--full` itself). It changes the screens for a while: only ever run on purpose, by a person.
        case displayCheck(String)
        /// `Petal --browser-check`: a run's own browser driven for real, headless, on pages of a local server it
        /// starts (BrowserCheck.swift). `--live <folder>`: with a real hidden display and a real installed browser: it
        /// changes the screens for a few seconds, so only ever run on purpose, by a person.
        case browserCheck(live: String?)
        /// `Petal --look-check <bundle id>`: what petal_look's text would answer for that app's front window, read
        /// only (LookCheck.swift): it never activates, clicks or types.
        case lookCheck(String)
        /// A tool's flag written wrong (`--snapshot` with no folder, a `--bench…` there isn't): its usage, printed
        /// before anything starts, and a non-zero exit. Never a dock.
        case usage(String)
        case dock
    }

    /// How each tool is written, for `.usage`.
    static let usages: [String: String] = [
        "--snapshot": "Petal --snapshot <folder>",
        "--display-check": "Petal --display-check <folder> [--full]",
        "--browser-check": "Petal --browser-check [--live <folder>]",
        "--look-check": "Petal --look-check <bundle id> [--find <word>] [--part <n>]",
        "--bench-windows-idle": "Petal --bench-windows-idle <window>",
        "--bench-windows": "Petal --bench-windows [--runs <n>] [--only <window>] [--json <file>] [--png <folder>]",
        "--bench-settings": "Petal --bench-settings [--runs <n>] [--only <window>] [--json <file>] [--png <folder>]",
        "--bench-notes": "Petal --bench-notes [--json <file>]",
        "--bench": "Petal --bench | --bench-dock [folder] | --bench-settings | --bench-windows | --bench-windows-child [settings] | --bench-windows-idle <window> | --bench-notes",
    ]

    static func parse(_ arguments: [String]) -> Launch {
        let words = Array(arguments.dropFirst())
        let first = words.first
        // `petal run … --mcp` is a command with --mcp among its own words.
        if words.contains("--mcp") && first != "run" { return .mcp }
        if let first, !first.hasPrefix("-") { return .command(words) }
        /// The word after `flag`, when there is one that isn't itself a flag.
        func value(after flag: String) -> String? {
            guard let index = words.firstIndex(of: flag), words.indices.contains(index + 1),
                  !words[index + 1].hasPrefix("-") else { return nil }
            return words[index + 1]
        }
        func usage(_ flag: String) -> Launch { .usage("usage: " + (usages[flag] ?? usages["--bench"]!)) }
        if words.contains("--restore-dock") { return .restoreDock }
        let known: Set<String> = ["--bench", "--bench-dock", "--bench-settings", "--bench-windows", "--bench-windows-child", "--bench-windows-idle", "--bench-notes"]
        if let unknown = words.first(where: { $0.hasPrefix(benchPrefix) && !known.contains($0) }) {
            return .usage("petal: no benchmark \"\(unknown)\"\n" + "usage: " + usages["--bench"]!)
        }
        if words.contains("--bench-windows-idle") {
            guard let name = value(after: "--bench-windows-idle") else { return usage("--bench-windows-idle") }
            return .benchWindowsIdle(name)
        }
        if words.contains("--bench-windows-child") { return .benchWindowsChild(settingsOnly: words.contains("settings")) }
        if let flag = ["--bench-settings", "--bench-windows"].first(where: words.contains) {
            for option in ["--runs", "--only", "--json", "--png"] where words.contains(option) {
                guard let given = value(after: option), option != "--runs" || Int(given).map({ $0 > 0 }) == true else { return usage(flag) }
            }
            return .benchWindows(settingsOnly: flag == "--bench-settings")
        }
        if words.contains("--bench-notes") {
            if words.contains("--json"), value(after: "--json") == nil { return usage("--bench-notes") }
            return .benchNotes
        }
        if words.contains("--bench-dock") { return .benchDock }
        if words.contains("--bench") { return .bench }
        if words.contains("--routines-check") { return .routinesCheck(ai: words.contains("--ai")) }
        if words.contains("--helpers-check") { return .helpersCheck(ai: words.contains("--ai")) }
        if words.contains("--viewer-check") { return .viewerCheck }
        if words.contains("--snapshot") {
            guard let folder = value(after: "--snapshot") else { return usage("--snapshot") }
            return .snapshot(folder)
        }
        if words.contains("--display-check") {
            guard let folder = value(after: "--display-check") else { return usage("--display-check") }
            return .displayCheck(folder)
        }
        if words.contains("--browser-check") {
            guard words.contains("--live") else { return .browserCheck(live: nil) }
            guard let folder = value(after: "--live") else { return usage("--browser-check") }
            return .browserCheck(live: folder)
        }
        if words.contains("--look-check") {
            guard let app = value(after: "--look-check") else { return usage("--look-check") }
            return .lookCheck(app)
        }
        if let first, ["-h", "--help", "-help"].contains(first) { return .help }
        // A flag this Petal doesn't know (another version's tool, or one written wrong): it says so and ends before
        // anything starts. Never a dock.
        if let unknown = words.first(where: { $0.hasPrefix("--") }) {
            return .usage("petal: no flag \"\(unknown)\" (petal --help lists the commands)")
        }
        // macOS's own launch arguments (-psn_…, -NSDocumentRevisionsDebugMode) start with one "-" and leave it a dock.
        return .dock
    }

    /// Whether a process started with these arguments is a dock: exactly what main.swift would start as one.
    static func isDock(arguments: [String]) -> Bool { parse(arguments) == .dock }

    /// Whether the process `pid` is a dock. Arguments that can't be read (it ended, or isn't ours) count as a dock,
    /// as every Petal did before: unsure, Petal keeps to one at a time.
    static func isDock(pid: pid_t) -> Bool {
        guard let arguments = arguments(of: pid) else { return true }
        return isDock(arguments: arguments)
    }

    /// A process's argv, read with sysctl's KERN_PROCARGS2: argc, the executable's path, padding, then argv.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // the executable's path
        while index < size && buffer[index] == 0 { index += 1 }   // its padding
        var arguments: [String] = []
        while arguments.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    /// The Dock guard's shell test (Setup.swift), the same rules as `isDock(arguments:)`: whether a process named
    /// Petal is running that is a dock. `ps -o comm=` is the program (argv[0], spaces and all), so what follows it in
    /// `ps -o args=` is its words: a first word that isn't a flag is a command (`petal run … -- npm run dev` may run
    /// for hours, and must never keep macOS's Dock hidden after the dock crashed), and so are help and the flags
    /// above (written wrong, they print their usage and end before a dock starts, so they're never one either), and
    /// so is any word starting with two dashes, known to this Petal or not (a newer Petal's check).
    /// Anything it can't read (the process ended, words that don't follow the program) counts as running: a guard
    /// unsure whether the dock runs leaves the Dock alone.
    static var shellDockRunning: String {
        let flags = (notDockFlags.sorted().map { "*\" \($0) \"*" } + ["*\" \(benchPrefix)\"*"]).joined(separator: "|")
        return """
        petal_dock() {
          for pid in $(pgrep -x Petal); do
            args="$(ps -o args= -p "$pid" 2>/dev/null)"; prog="$(ps -o comm= -p "$pid" 2>/dev/null)"
            words="${args#"$prog"}"
            case "$args" in "$prog"*) ;; *) return 0 ;; esac
            case "$words" in ''|' '*) ;; *) return 0 ;; esac
            first="${words# }"; first="${first%% *}"
            case "$first" in -h|--help|-help) continue ;; ''|-*) ;; *) continue ;; esac
            case "$words " in
              \(flags)) ;;
              *" --"*) ;;
              *) return 0 ;;
            esac
          done
          return 1
        }
        """
    }
}
