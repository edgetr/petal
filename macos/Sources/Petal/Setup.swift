import AppKit
import Observation

/// Getting each AI ready without a terminal: Petal installs it with its maker's own installer when it's missing,
/// and runs its sign-in, which finishes in the browser with the person's own account.
@MainActor @Observable
final class AISetup {
    enum State: Equatable {
        case checking, missing, installing, signedOut, signingIn, ready(String), failed(String)
    }
    private(set) var states: [Provider: State] = [:]
    @ObservationIgnored private var polls: [Provider: Timer] = [:]

    var app: PetalApp { PetalApp.shared }

    func state(_ provider: Provider) -> State { states[provider] ?? .checking }

    func refreshAll() { for provider in Provider.allCases { refresh(provider) } }

    func refresh(_ provider: Provider) {
        guard !Headless.on else { return }   // a benchmark runs nothing
        Task {
            if app.paths[provider] == nil { await app.lookFor(provider) }
            guard let path = app.paths[provider] else { states[provider] = .missing; return }
            let status = await Self.run(path, provider.statusArguments, environment: app.childEnvironment, timeout: 20)
            if let who = provider.signedIn(status: status.status, output: status.output) {
                states[provider] = .ready(who)
                polls[provider]?.invalidate()
            } else if states[provider] != .signingIn {
                states[provider] = .signedOut
            }
        }
    }

    func install(_ provider: Provider) {
        states[provider] = .installing
        Task {
            let result = await Self.run("/bin/bash", ["-c", provider.installer], environment: app.childEnvironment)
            await app.lookFor(provider)
            guard result.status == 0, app.paths[provider] != nil else {
                states[provider] = .failed("\(provider.appName) didn't install. Check your connection and try again.")
                return
            }
            signIn(provider)
        }
    }

    func signIn(_ provider: Provider) {
        guard let path = app.paths[provider] else { states[provider] = .missing; return }
        states[provider] = .signingIn
        let environment = app.childEnvironment
        Task {
            let result = await Self.run(path, provider.signInArguments, environment: environment, timeout: 600) { line in
                // If it shows a link instead of opening one, open it.
                if let range = line.range(of: #"https://\S+"#, options: .regularExpression), !line.lowercased().contains("opening"),
                   let url = URL(string: String(line[range])) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
            if result.status != 0 && states[provider] == .signingIn {
                states[provider] = .failed("Signing in didn't finish. Try again.")
            }
            refresh(provider)
        }
        polls[provider]?.invalidate()
        polls[provider] = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(provider) }
        }
    }

    struct Result: Sendable { let status: Int32; let output: String }

    /// Runs a command off the main thread, handing each line of its output to `line` as it comes.
    static func run(_ path: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 300,
                    line: (@Sendable (String) -> Void)? = nil) async -> Result {
        await Task.detached { runBlocking(path, arguments, environment: environment, timeout: timeout, line: line) }.value
    }

    nonisolated private static func runBlocking(_ path: String, _ arguments: [String], environment: [String: String],
                                            timeout: TimeInterval, line: (@Sendable (String) -> Void)?) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        let output = TextBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for text in buffer.lines(adding: chunk) {
                line?(text)
                output.append(text + "\n")
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return Result(status: -1, output: "") }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            finished.wait()
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // What's left in the pipe, then a last line with no newline yet: a long answer (Codex's model list is over
        // half a megabyte on one line) can still be on its way when the process ends.
        for text in buffer.lines(adding: pipe.fileHandleForReading.readDataToEndOfFile()) {
            line?(text)
            output.append(text + "\n")
        }
        let rest = buffer.rest()
        if !rest.isEmpty {
            line?(rest)
            output.append(rest)
        }
        return Result(status: process.terminationStatus, output: output.text)
    }
}

/// Text collected from more than one thread.
final class TextBox: @unchecked Sendable {
    private var value = ""
    private let lock = NSLock()
    func append(_ text: String) { lock.lock(); value += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

/// Keeps macOS's Dock from staying hidden when Petal can't give it back itself: a small job macOS runs every
/// 30 seconds that, when Petal isn't running (a crash, Force Quit) and the Dock's own settings are still saved,
/// puts them back. It does the same for Do Not Disturb that Petal turned on while holding notifications (Quiet). If
/// Petal.app has been deleted, it also removes itself.
@MainActor
enum DockGuard {
    static let label = "tech.edgetr.petal.guard"
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist") }

    static func install() {
        let app = Bundle.main.bundlePath
        let backup = Config.folder.appending(path: "macos-dock.json").path
        let quiet = Quiet.marker.path
        let off = Config.supportFolder.appending(path: "quiet-off.txt").path
        let script = """
        app='\(app)'; backup='\(backup)'; plist='\(plist.path)'; quiet='\(quiet)'; off='\(off)'
        \(PetalProcess.shellDockRunning)
        if [ -f "$quiet" ] && ! petal_dock; then
          if grep -q shortcut "$quiet"; then mkdir -p "$(dirname "$off")"; printf off > "$off"; shortcuts run '\(Quiet.shortcutName)' --input-path "$off"; fi
          rm -f "$quiet"
        fi
        if [ ! -d "$app" ] && [ ! -f "$backup" ]; then launchctl bootout gui/$(id -u)/\(label) 2>/dev/null; rm -f "$plist"; exit 0; fi
        [ -f "$backup" ] || exit 0
        if [ -d "$app" ] && petal_dock; then exit 0; fi
        if [ "$(plutil -extract autohide raw -o - "$backup" 2>/dev/null)" = "true" ]; then
          defaults write com.apple.dock autohide -bool true
        else
          defaults write com.apple.dock autohide -bool false
        fi
        delay="$(plutil -extract autohide-delay raw -o - "$backup" 2>/dev/null)"
        case "$delay" in ''|*[!0-9.]*) defaults delete com.apple.dock autohide-delay 2>/dev/null ;; *) defaults write com.apple.dock autohide-delay -float "$delay" ;; esac
        if grep -q '"autohide-time-modifier"' "$backup"; then
          pace="$(plutil -extract autohide-time-modifier raw -o - "$backup" 2>/dev/null)"
          case "$pace" in ''|*[!0-9.]*) defaults delete com.apple.dock autohide-time-modifier 2>/dev/null ;; *) defaults write com.apple.dock autohide-time-modifier -float "$pace" ;; esac
        fi
        if grep -q '"orientation"' "$backup"; then
          side="$(plutil -extract orientation raw -o - "$backup" 2>/dev/null)"
          case "$side" in left|right|bottom) defaults write com.apple.dock orientation -string "$side" ;; *) defaults delete com.apple.dock orientation 2>/dev/null ;; esac
        fi
        if grep -q '"tilesize"' "$backup"; then
          size="$(plutil -extract tilesize raw -o - "$backup" 2>/dev/null)"
          case "$size" in ''|*[!0-9.]*) defaults delete com.apple.dock tilesize 2>/dev/null ;; *) defaults write com.apple.dock tilesize -float "$size" ;; esac
        fi
        rm -f "$backup"
        killall Dock
        """
        let contents: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sh", "-c", script],
                                       "StartInterval": 30, "RunAtLoad": true, "ProcessType": "Background"]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0) else { return }
        if (try? Data(contentsOf: plist)) == data { return }   // already in place, for this copy of Petal
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: plist, options: .atomic)
        let uid = String(getuid())
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist.path])
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
