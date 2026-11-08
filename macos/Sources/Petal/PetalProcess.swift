import Darwin
import Foundation

/// Which of the processes running Petal's code is a dock. They all share Petal's bundle id and name: the dock, but
/// also `Petal --mcp` (the AI's tools), `petal <command>` from a shell, the benchmarks, snapshots and checks. Only a
/// dock counts as "Petal running": the one-at-a-time check at launch, `petal doctor` and the Dock guard.
enum PetalProcess {
    /// Flags that start Petal as something other than a dock (main.swift handles each before the dock starts).
    static let notDockFlags: Set<String> = ["--snapshot", "--routines-check", "--mcp", "--restore-dock"]
    /// Every benchmark: --bench, --bench-dock, --bench-settings, --bench-windows, --bench-windows-child, -idle.
    static let benchPrefix = "--bench"

    /// Whether a process started with these arguments (argv, its first being the program) is a dock. A first word
    /// that isn't a flag is a command (`petal mode`, `doctor`, `run`, or one it doesn't know): never a dock.
    /// macOS's own launch arguments (-psn_…, -NSDocumentRevisionsDebugMode) start with "-" and leave it a dock.
    static func isDock(arguments: [String]) -> Bool {
        let words = arguments.dropFirst()
        if let first = words.first, !first.hasPrefix("-") { return false }
        return !words.contains { notDockFlags.contains($0) || $0.hasPrefix(benchPrefix) }
    }

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
    /// for hours, and must never keep macOS's Dock hidden after the dock crashed), and so are the flags above.
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
            case "$first" in ''|-*) ;; *) continue ;; esac
            case "$words " in
              \(flags)) ;;
              *) return 0 ;;
            esac
          done
          return 1
        }
        """
    }
}
