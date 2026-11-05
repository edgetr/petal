import AppKit
import Observation

/// Getting Claude ready without a terminal: Petal installs Claude Code with Anthropic's own installer when it's
/// missing, and runs its sign-in, which finishes in the browser.
@MainActor @Observable
final class ClaudeSetup {
    enum State: Equatable {
        case checking, missing, installing, signedOut, signingIn, ready(String), failed(String)
    }
    private(set) var state: State = .checking
    @ObservationIgnored private var poll: Timer?

    var app: PetalApp { PetalApp.shared }

    func refresh() {
        Task {
            if app.claudePath == nil { await app.lookForClaude() }
            guard let claude = app.claudePath else { state = .missing; return }
            let status = await Self.run(claude, ["auth", "status", "--json"], environment: app.childEnvironment)
            let info = (try? JSONSerialization.jsonObject(with: Data(status.output.utf8))) as? [String: Any]
            if info?["loggedIn"] as? Bool == true {
                state = .ready(info?["email"] as? String ?? "")
                poll?.invalidate()
            } else if state != .signingIn {
                state = .signedOut
            }
        }
    }

    /// Anthropic's installer puts `claude` in ~/.local/bin; then sign in.
    func install() {
        state = .installing
        Task {
            let result = await Self.run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], environment: app.childEnvironment)
            await app.lookForClaude()
            guard result.status == 0, app.claudePath != nil else {
                state = .failed("Claude Code didn't install. Check your connection and try again.")
                return
            }
            signIn()
        }
    }

    /// Claude Code's own sign-in: it opens the browser, and the person signs in to their Claude account there.
    func signIn() {
        guard let claude = app.claudePath else { state = .missing; return }
        state = .signingIn
        let environment = app.childEnvironment
        Task {
            let result = await Self.run(claude, ["auth", "login", "--claudeai"], environment: environment, timeout: 600) { line in
                // If it shows a link instead of opening one, open it.
                if let range = line.range(of: #"https://\S+"#, options: .regularExpression), !line.lowercased().contains("opening") {
                    DispatchQueue.main.async { NSWorkspace.shared.open(URL(string: String(line[range]))!) }
                }
            }
            if result.status != 0 && state == .signingIn { state = .failed("Signing in didn't finish. Try again.") }
            refresh()
        }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
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
        output.append(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
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
/// puts them back. If Petal.app has been deleted, it also removes itself.
@MainActor
enum DockGuard {
    static let label = "tech.edgetr.petal.guard"
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist") }

    static func install() {
        let app = Bundle.main.bundlePath
        let backup = Config.folder.appending(path: "macos-dock.json").path
        let script = """
        app='\(app)'; backup='\(backup)'; plist='\(plist.path)'
        if [ ! -d "$app" ] && [ ! -f "$backup" ]; then launchctl bootout gui/$(id -u)/\(label) 2>/dev/null; rm -f "$plist"; exit 0; fi
        [ -f "$backup" ] || exit 0
        if [ -d "$app" ] && pgrep -qx Petal; then exit 0; fi
        if [ "$(plutil -extract autohide raw -o - "$backup" 2>/dev/null)" = "true" ]; then
          defaults write com.apple.dock autohide -bool true
        else
          defaults write com.apple.dock autohide -bool false
        fi
        delay="$(plutil -extract autohide-delay raw -o - "$backup" 2>/dev/null)"
        case "$delay" in ''|*[!0-9.]*) defaults delete com.apple.dock autohide-delay 2>/dev/null ;; *) defaults write com.apple.dock autohide-delay -float "$delay" ;; esac
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
