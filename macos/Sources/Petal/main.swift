import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: Config!
    private var dock: DockController!
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config()
        // PETAL_KEEP_DOCK=1 leaves macOS's Dock alone, for working on Petal next to it.
        if config.replaceDock && ProcessInfo.processInfo.environment["PETAL_KEEP_DOCK"] != "1" {
            SystemDock.replace()
        } else {
            SystemDock.restore()   // a crash may have left it hidden
        }
        dock = DockController(config: config)

        // Being killed (logout, `killall Petal`) gives the Dock back too, not only quitting from the menu.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemDock.restore()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
