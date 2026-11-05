import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
        app.setActivationPolicy(.prohibited)
        Snapshot.run(to: CommandLine.arguments[index + 1])
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
