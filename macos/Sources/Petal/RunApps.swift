import AppKit

/// Which processes are a run's own, not the person's: the browsers Petal started for runs (RunBrowser.swift). A run's
/// browser is the same app as the person's own, as a second process, so everything that names the person's running
/// apps (the dock, window lists, previews, the tools, routines, Open all) asks here, never macOS's whole list.
/// AppKit only, in a file of its own: the pure checks compile sources that look an app up.
enum RunApps {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: [pid_t: String] = [:]

    /// `pid` is a process Petal started for a run: never one of the person's apps.
    static func isRun(_ pid: pid_t) -> Bool { lock.withLock { pids[pid] != nil } }

    /// A run's copy of this app is going now (the person's own needs opening as a new one).
    static func running(bundle: String) -> Bool { lock.withLock { pids.values.contains(bundle) } }

    /// From before it has a window until it's ended.
    static func register(_ pid: pid_t, bundle: String) { lock.withLock { pids[pid] = bundle } }
    static func forget(_ pid: pid_t) { lock.withLock { pids[pid] = nil } }
}

extension NSWorkspace {
    /// The person's running apps: every one but a process Petal started for a run.
    var personsApplications: [NSRunningApplication] {
        runningApplications.filter { !RunApps.isRun($0.processIdentifier) }
    }
}

extension NSRunningApplication {
    /// The person's running copies of an app: never one Petal started for a run (the same app, as a second process).
    static func persons(withBundleIdentifier bundle: String) -> [NSRunningApplication] {
        runningApplications(withBundleIdentifier: bundle).filter { !RunApps.isRun($0.processIdentifier) }
    }
}
