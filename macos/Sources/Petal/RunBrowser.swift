import AppKit
import Darwin
import Security

/// The pipe to one browser Petal started: requests go down one end, replies and events come up the other
/// (`--remote-debugging-pipe`: the browser reads descriptor 3 and writes 4). No port is opened, so nothing else on
/// the Mac can drive it. The browser is Petal's own child; it ends when the pipe closes, so a Petal that crashes
/// takes its browsers with it.
final class BrowserPipe: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case closed
        case timedOut
        /// The browser's own refusal, in its words.
        case refused(String)

        var words: String {
            switch self {
            case .closed: return "The browser closed."
            case .timedOut: return "The browser didn't answer in time."
            case .refused(let why): return why
            }
        }
    }

    private final class Waiter {
        let done = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Failure>?
    }

    let pid: pid_t
    private let writeFD: Int32
    private let readFD: Int32
    private let lock = NSLock()
    private let writing = NSLock()
    private var inbox = CDP.Inbox<Waiter>()
    private var shut = false
    private var gone = false
    private let exited = DispatchSemaphore(value: 0)
    /// On the reading thread, in the order the browser sent them: kept short, never a request that waits.
    private var handler: ((_ method: String, _ params: [String: Any], _ session: String?) -> Void)?
    var onEvent: ((_ method: String, _ params: [String: Any], _ session: String?) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    private var hungUp = false

    private init(pid: pid_t, writeFD: Int32, readFD: Int32) {
        self.pid = pid
        self.writeFD = writeFD
        self.readFD = readFD
    }

    /// The pipe is closed (the browser ended, or Petal closed it).
    var closed: Bool { lock.withLock { shut } }
    /// The browser's process is gone.
    var ended: Bool { lock.withLock { gone } }

    /// Starts `executable` with the pipe on its descriptors 3 and 4 and nothing else of Petal's open in it, in a
    /// process group of its own (so it and everything it starts end together), with a bare environment. Never through
    /// Launch Services: it's Petal's child, not an app the person opened.
    static func start(executable: String, arguments: [String]) -> BrowserPipe? {
        var down: [Int32] = [-1, -1], up: [Int32] = [-1, -1]
        guard pipe(&down) == 0 else { return nil }
        guard pipe(&up) == 0 else { close(down[0]); close(down[1]); return nil }
        // Above the descriptors the browser is given, and closed in anything else Petal starts.
        func high(_ fd: Int32) -> Int32 {
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 10)
            close(fd)
            return moved
        }
        let childRead = high(down[0]), parentWrite = high(down[1]), parentRead = high(up[0]), childWrite = high(up[1])
        guard childRead >= 0, parentWrite >= 0, parentRead >= 0, childWrite >= 0 else {
            for fd in [childRead, parentWrite, parentRead, childWrite] where fd >= 0 { close(fd) }
            return nil
        }
        // A browser that went never ends Petal with a signal: a write to it fails instead.
        _ = fcntl(parentWrite, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, childRead, 3)
        posix_spawn_file_actions_adddup2(&actions, childWrite, 4)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only what the actions above set up is open in it; and a group of its own.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let home = NSHomeDirectory()
        let environment = ["HOME=" + home, "USER=" + NSUserName(), "LOGNAME=" + NSUserName(), "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                           "TMPDIR=" + NSTemporaryDirectory(), "LANG=en_US.UTF-8"]
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        close(childRead)
        close(childWrite)
        guard status == 0, pid > 0 else {
            close(parentWrite)
            close(parentRead)
            return nil
        }
        let made = BrowserPipe(pid: pid, writeFD: parentWrite, readFD: parentRead)
        let reader = Thread { made.read() }
        reader.name = "petal.browser.read"
        reader.stackSize = 1 << 20
        reader.start()
        let reaper = Thread { made.reap() }
        reaper.name = "petal.browser.wait"
        reaper.start()
        return made
    }

    private func read() {
        var splitter = CDP.Splitter()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = Darwin.read(readFD, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            for message in splitter.take(Data(buffer[0..<count])) {
                switch CDP.parse(message) {
                case .reply(let id, let result, let error):
                    let waiter = lock.withLock { inbox.take(id) }
                    waiter?.result = error.map { .failure(.refused($0)) } ?? .success(result)
                    waiter?.done.signal()
                case .event(let method, let params, let session):
                    onEvent?(method, params, session)
                case .junk: break
                }
            }
            if splitter.overflowed { break }
        }
        shutDown()
    }

    private func reap() {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        lock.withLock { gone = true }
        exited.signal()
        shutDown()
    }

    /// Everyone waiting hears the browser closed; nothing more is sent.
    private func shutDown() {
        let waiting: [Waiter] = lock.withLock {
            guard !shut else { return [] }
            shut = true
            return inbox.drain()
        }
        for waiter in waiting {
            waiter.result = .failure(.closed)
            waiter.done.signal()
        }
    }

    private func write(_ data: Data) -> Bool {
        writing.lock()
        defer { writing.unlock() }
        guard !lock.withLock({ hungUp }) else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard var at = raw.baseAddress else { return false }
            var left = raw.count
            while left > 0 {
                let wrote = Darwin.write(writeFD, at, left)
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return false }
                at += wrote
                left -= wrote
            }
            return true
        }
    }

    /// One request and its answer. Never on the main thread: it waits for the browser, `timeout` seconds at most.
    func call(_ method: String, _ params: [String: Any] = [:], session: String? = nil, timeout: TimeInterval = 15) -> Result<[String: Any], Failure> {
        let waiter = Waiter()
        let id: Int? = lock.withLock { shut ? nil : inbox.add(waiter) }
        guard let id else { return .failure(.closed) }
        guard let data = CDP.frame(id: id, method: method, params: params, session: session), write(data) else {
            _ = lock.withLock { inbox.take(id) }
            return .failure(.closed)
        }
        guard waiter.done.wait(timeout: .now() + timeout) == .success else {
            // Given up: an answer that comes later is nobody's.
            if lock.withLock({ inbox.take(id) }) != nil { return .failure(.timedOut) }
            waiter.done.wait()
            return waiter.result ?? .failure(.timedOut)
        }
        return waiter.result ?? .failure(.closed)
    }

    /// A request nobody waits for (from the reading thread, where waiting would stop the reading). It's written on a
    /// queue of its own, in order: the reading thread never writes, so it never stops reading while a write waits for
    /// the browser, which may itself be waiting to be read.
    func post(_ method: String, _ params: [String: Any] = [:], session: String? = nil) {
        let id: Int? = lock.withLock { shut ? nil : inbox.add(Waiter()) }
        guard let id else { return }
        guard let data = CDP.frame(id: id, method: method, params: params, session: session) else {
            _ = lock.withLock { inbox.take(id) }
            return
        }
        posting.async { [weak self] in _ = self?.write(data) }
        // Its answer is dropped when it comes.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in _ = self?.lock.withLock { self?.inbox.take(id) } }
    }

    private let posting = DispatchQueue(label: "petal.browser.post", qos: .userInitiated)

    /// Closes Petal's end of the pipe and nothing else: a browser started with the pipe ends itself when it closes
    /// (what happens to every run's browser if Petal crashes). Twice does nothing.
    func hangUp() {
        let first: Bool = lock.withLock {
            let was = hungUp
            hungUp = true
            return !was
        }
        if first { writing.withLock { _ = Darwin.close(writeFD) } }
    }

    /// Ends the browser and everything it started, now. Its process group gets no chance to object: the profile is
    /// thrown away with it, so there's nothing for it to save.
    func kill() {
        let already = lock.withLock { gone }
        if !already {
            Darwin.kill(-pid, SIGKILL)
            Darwin.kill(pid, SIGKILL)
        }
        shutDown()
    }

    /// Waits for the process to be gone, `seconds` at most. True when it is.
    func waitForExit(_ seconds: TimeInterval) -> Bool {
        if ended { return true }
        if exited.wait(timeout: .now() + seconds) == .success {
            exited.signal()
            return true
        }
        return ended
    }

    deinit {
        if !hungUp { close(writeFD) }
        close(readFD)
    }
}

/// One run's own browser: a separate instance of a browser the person has installed, started by Petal as its child
/// with a profile of its own (signed in to nothing, no extensions, no sync), its window on the run's hidden display,
/// driven over the DevTools pipe. Nothing here needs the pointer, the keyboard or anything in front. It ends with its
/// run, however the run ends: the process is ended and the profile folder removed.
///
/// Everything that asks the browser something runs on `queue`, one thing at a time, never the main thread.
final class RunBrowser: @unchecked Sendable {
    /// Which browser, and how it's started.
    struct Spec {
        let bundle: String
        let name: String
        let executable: String
        /// No window at all (the headless shell a check uses): nothing is placed.
        var headless = false
        /// More arguments (a check's).
        var extra: [String] = []
        /// The running process is that browser, signed by its maker: only then is a page's address believed for the
        /// vault (as VaultReader.isBrowser, for the browsers the person runs).
        let verify: @Sendable (pid_t) -> Bool
    }

    struct Problem: Error, Equatable {
        let words: String
        init(_ words: String) { self.words = words }
        static let stale = Problem(RunBrowserRules.stale)
        static let closed = Problem("Your browser closed (it crashed, or its run's display went). Call petal_browser open to start again.")
    }

    struct Tab: Equatable {
        var id: String
        var number: Int
        var url = ""
        var title = ""
    }

    /// One frame of a page as it was read: whose session it answers on, its document, and Petal's world in it.
    struct FrameAt: Equatable {
        var session: String
        var id: String
        var url: String
        var loader: String
        var parent: Int
        var context = 0
        /// The read (`collect`) its controls' numbers came from.
        var generation = 0
    }

    /// The last read of the tab worked in: what an id stands for.
    struct Kept {
        var outline: BrowserOutline
        var frames: [FrameAt]
        var target: String
        var stamp: Int
        var made = Date()
    }

    struct Read {
        var title: String
        var address: String
        var tab: String
        var tabs: Int
        var text: String
        var count: Int
        var left: String
    }

    let spec: Spec
    let group: String
    let profile: String
    let pipe: BrowserPipe
    /// A number that stands for its window where a Buy is kept (Vault.Checkout goes by window): far from any the
    /// window server gives out.
    let window: UInt32
    let queue: DispatchQueue
    /// A page moved on, another tab was picked or one closed: a Buy said in this browser is over (on any thread).
    var onLeft: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var tabs: [String: Tab] = [:]
    private var numbers = 0
    private var sessions: [String: String] = [:]
    /// Frames in a process of their own, by the session that holds them.
    private var children: [String: [(session: String, target: String)]] = [:]
    private var loading: [String: Set<String>] = [:]
    private var activity = Date()
    private var happened: [String] = []
    private var current: String?
    /// Counts every time a tab's page becomes another: a read from before is no use.
    private var stamp = 0
    private var kept: Kept?
    private var over = false
    private var mine: Set<String> = []

    nonisolated(unsafe) private static var windows: UInt32 = 0xF000_0000
    private static let windowsLock = NSLock()

    private init(spec: Spec, group: String, profile: String, pipe: BrowserPipe) {
        self.spec = spec
        self.group = group
        self.profile = profile
        self.pipe = pipe
        window = Self.windowsLock.withLock { Self.windows += 1; return Self.windows }
        queue = DispatchQueue(label: "petal.browser." + group, qos: .userInitiated)
        pipe.onEvent = { [weak self] method, params, session in self?.event(method, params, session) }
    }

    var pid: pid_t { pipe.pid }
    var alive: Bool { !pipe.closed && !lock.withLock { over } }
    /// The browser is the one it says it is, signed by its maker (checked now, on its running code).
    var verified: Bool { spec.verify(pipe.pid) }

    // MARK: Starting and ending

    /// Where a run's browser window goes on its display (the window server's coordinates): under the display's own
    /// menu bar, with a little room around it.
    static func windowFrame(on display: CGRect) -> CGRect {
        let width = min(1280, max(600, display.width - 80)), height = min(800, max(400, display.height - 90))
        return CGRect(x: display.minX + 40, y: display.minY + 50, width: width, height: height)
    }

    /// Starts the browser with `profile` (made here, for it alone) and gets its first tab ready: with a window, made
    /// at `frame` over the pipe and checked to be there. Off the main thread: a browser takes a moment to start.
    /// On any failure nothing is left: no process, no folder.
    static func launch(spec: Spec, group: String, profile: String, frame: CGRect?) -> Result<RunBrowser, Problem> {
        do {
            try FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(Problem("Petal couldn't make a folder for the browser's profile."))
        }
        let arguments = RunBrowserRules.arguments(profile: profile, frame: spec.headless ? nil : frame) + spec.extra
        guard let pipe = BrowserPipe.start(executable: spec.executable, arguments: arguments) else {
            try? FileManager.default.removeItem(atPath: profile)
            return .failure(Problem("\(spec.name) couldn't be started for a run."))
        }
        let browser = RunBrowser(spec: spec, group: group, profile: profile, pipe: pipe)
        if let problem = browser.open(frame: spec.headless ? nil : frame) {
            browser.end(wait: 2)
            return .failure(problem)
        }
        return .success(browser)
    }

    /// The first words with the browser, and its first tab.
    private func open(frame: CGRect?) -> Problem? {
        // A browser still starting answers once it's up.
        guard case .success = pipe.call("Target.setDiscoverTargets", ["discover": true], timeout: 30) else {
            return Problem("\(spec.name) started but didn't answer Petal, so it was ended.")
        }
        // Nothing is saved to the Mac from a run's browser.
        _ = pipe.call("Browser.setDownloadBehavior", ["behavior": "deny", "eventsEnabled": true])
        var target: String?
        if let frame {
            let made = pipe.call("Target.createTarget", ["url": "about:blank", "newWindow": true, "background": true,
                                                          "left": Int(frame.minX), "top": Int(frame.minY), "width": Int(frame.width), "height": Int(frame.height)])
            target = (try? made.get())?["targetId"] as? String
            guard let target else { return Problem("\(spec.name) wouldn't open a window for the run, so it was ended.") }
            // On the run's display, by the browser's own word; asked once more to go there, and ended if it won't:
            // never left on the person's screen.
            if !placed(target, at: frame) { return Problem("\(spec.name) wouldn't keep its window on the run's display, so Petal ended it rather than show it on the person's screen.") }
        } else {
            let listed = (try? pipe.call("Target.getTargets").get())?["targetInfos"] as? [[String: Any]] ?? []
            target = listed.first { $0["type"] as? String == "page" }?["targetId"] as? String
            if target == nil { target = (try? pipe.call("Target.createTarget", ["url": "about:blank"]).get())?["targetId"] as? String }
        }
        guard let target, attach(target) != nil else { return Problem("\(spec.name) gave Petal no tab to work in, so it was ended.") }
        lock.withLock {
            mine.insert(target)
            current = target
            if tabs[target] == nil { numbers += 1; tabs[target] = Tab(id: target, number: numbers) }
        }
        return nil
    }

    /// The window holding `target` is at `frame` (its middle inside it), asked to go there once if it isn't.
    private func placed(_ target: String, at frame: CGRect) -> Bool {
        func bounds() -> (window: Int, frame: CGRect)? {
            guard let found = try? pipe.call("Browser.getWindowForTarget", ["targetId": target]).get(),
                  let number = (found["windowId"] as? NSNumber)?.intValue, let box = found["bounds"] as? [String: Any] else { return nil }
            func value(_ key: String) -> CGFloat { CGFloat((box[key] as? NSNumber)?.doubleValue ?? 0) }
            return (number, CGRect(x: value("left"), y: value("top"), width: value("width"), height: value("height")))
        }
        let room = frame.insetBy(dx: -60, dy: -60)
        for attempt in 0..<3 {
            guard let now = bounds() else { return false }
            if room.contains(CGPoint(x: now.frame.midX, y: now.frame.midY)) { return true }
            guard attempt < 2 else { break }
            _ = pipe.call("Browser.setWindowBounds", ["windowId": now.window, "bounds": ["left": Int(frame.minX), "top": Int(frame.minY), "width": Int(frame.width),
                                                                                         "height": Int(frame.height), "windowState": "normal"]])
            usleep(200_000)
        }
        return false
    }

    /// Ends it: the process and everything it started, then its profile folder. `wait`: how long to wait for the
    /// process to be gone before the folder goes (the rest of that happens off this thread). Twice does nothing.
    func end(wait: TimeInterval = 0) {
        let first: Bool = lock.withLock {
            let was = over
            over = true
            return !was
        }
        guard first else { return }
        pipe.kill()
        let pipe = self.pipe, profile = self.profile
        let clear = {
            _ = pipe.waitForExit(3)
            RunBrowsers.removeProfile(profile)
        }
        if wait > 0, pipe.waitForExit(wait) {
            RunBrowsers.removeProfile(profile)
        } else {
            DispatchQueue.global(qos: .utility).async(execute: clear)
        }
    }

    // MARK: What the browser says by itself

    private func event(_ method: String, _ params: [String: Any], _ session: String?) {
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page", let id = info["targetId"] as? String else { return }
            lock.withLock {
                if tabs[id] == nil {
                    numbers += 1
                    tabs[id] = Tab(id: id, number: numbers)
                    // One a page opened by itself: said, and left where it is.
                    if info["openerId"] != nil, !mine.contains(id) { happened.append("The page opened a new tab (t\(numbers)). tab switches to it.") }
                }
                tabs[id]?.url = info["url"] as? String ?? ""
                tabs[id]?.title = info["title"] as? String ?? ""
            }
        case "Target.targetDestroyed":
            guard let id = params["targetId"] as? String else { return }
            let was: Bool = lock.withLock {
                guard tabs.removeValue(forKey: id) != nil else { return false }
                if let session = sessions.removeValue(forKey: id) {
                    children[session] = nil
                    loading[session] = nil
                }
                if current == id {
                    current = tabs.values.max { $0.number < $1.number }?.id
                    stamp += 1
                }
                return true
            }
            if was { onLeft?() }
        case "Target.attachedToTarget":
            guard let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "iframe", let parent = session,
                  let child = params["sessionId"] as? String, let target = info["targetId"] as? String else { return }
            lock.withLock { children[parent, default: []].append((child, target)) }
            // A frame in a process of its own: its pages and its own frames are heard of too.
            pipe.post("Page.enable", session: child)
            pipe.post("DOM.enable", session: child)
            pipe.post("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], session: child)
        case "Target.detachedFromTarget":
            guard let gone = params["sessionId"] as? String else { return }
            lock.withLock {
                for key in children.keys { children[key]?.removeAll { $0.session == gone } }
                children[gone] = nil
                loading[gone] = nil
            }
        case "Page.frameStartedLoading":
            guard let session, let frame = params["frameId"] as? String else { return }
            lock.withLock { loading[session, default: []].insert(frame); activity = Date() }
        case "Page.frameStoppedLoading":
            guard let session, let frame = params["frameId"] as? String else { return }
            lock.withLock {
                // The page's own frame done: so is everything in it that this session was told had started.
                if sessions[frame] == session { loading[session] = [] } else { loading[session]?.remove(frame) }
                activity = Date()
            }
        case "Page.frameDetached":
            // A frame that went, or moved to a process of its own (its own session says when it's done from then
            // on): this session hears no more of its loading.
            guard let session, let frame = params["frameId"] as? String else { return }
            lock.withLock { loading[session]?.remove(frame); activity = Date() }
        case "Page.frameNavigated", "Page.navigatedWithinDocument":
            guard let session else { return }
            let top: Bool
            if method == "Page.frameNavigated" {
                top = ((params["frame"] as? [String: Any])?["parentId"] as? String ?? "").isEmpty
            } else {
                top = lock.withLock { sessions.contains { $0.value == session && $0.key == params["frameId"] as? String } }
            }
            let page: Bool = lock.withLock {
                activity = Date()
                guard top, sessions.values.contains(session) else { return false }
                if method == "Page.frameNavigated" { stamp += 1 }
                return true
            }
            if page { onLeft?() }
        case "Page.javascriptDialogOpening":
            // Nobody is there to answer a page's own message: an alert is closed, a question is answered no.
            let type = params["type"] as? String ?? "alert"
            let said = UIMap.truncate(UIMap.tidy(params["message"] as? String ?? ""), 300)
            let accept = type == "alert" || type == "beforeunload"
            pipe.post("Page.handleJavaScriptDialog", ["accept": accept], session: session)
            if type != "beforeunload" {
                lock.withLock { happened.append("The page showed a message\(said.isEmpty ? "" : ": “\(said)”") (\(accept ? "closed" : "answered Cancel")).") }
            }
        case "Page.fileChooserOpened":
            lock.withLock { happened.append("The page asked for a file to upload: choosing a file isn't built in a run's browser, so none was given.") }
        case "Browser.downloadWillBegin":
            let note = RunBrowserRules.downloadRefused(params["suggestedFilename"] as? String ?? "", from: params["url"] as? String ?? "")
            lock.withLock { happened.append(note) }
        case "Inspector.targetCrashed":
            lock.withLock { happened.append("The page crashed. reload loads it again.") }
        default: onOther?(method, params, session)
        }
    }

    /// Anything else the browser says (a check's own conversation with it), on the reading thread.
    var onOther: ((_ method: String, _ params: [String: Any], _ session: String?) -> Void)?

    /// What happened by itself since this was last asked (a message closed, a download refused, a new tab), once.
    func notes() -> [String] {
        lock.withLock {
            let list = happened
            happened = []
            return list
        }
    }

    // MARK: Tabs

    private func attach(_ target: String) -> String? {
        if let known = lock.withLock({ sessions[target] }) { return known }
        guard let session = (try? pipe.call("Target.attachToTarget", ["targetId": target, "flatten": true]).get())?["sessionId"] as? String else { return nil }
        lock.withLock { sessions[target] = session }
        guard case .success = pipe.call("Page.enable", session: session) else { return nil }
        _ = pipe.call("DOM.enable", session: session)
        _ = pipe.call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], session: session)
        // A page behaves as if it had the keyboard, though nothing of it is in front.
        _ = pipe.call("Emulation.setFocusEmulationEnabled", ["enabled": true], session: session)
        // A page asking for a file never puts a file dialog on the screen.
        _ = pipe.call("Page.setInterceptFileChooserDialog", ["enabled": true], session: session)
        return session
    }

    /// The tab worked in and its session, or why there's none.
    private func working() -> Result<(target: String, session: String), Problem> {
        guard alive else { return .failure(.closed) }
        guard let target = lock.withLock({ current }) else { return .failure(Problem("No tab is open. petal_browser open opens one.")) }
        guard let session = attach(target) else { return .failure(.closed) }
        return .success((target, session))
    }

    func tabList() -> [(tab: Tab, current: Bool)] {
        lock.withLock {
            tabs.values.sorted { $0.number < $1.number }.map { ($0, $0.id == current) }
        }
    }

    private func tab(named name: String) -> Tab? {
        let word = name.trimmingCharacters(in: .whitespaces).lowercased()
        let number = Int(word.hasPrefix("t") ? String(word.dropFirst()) : word)
        return lock.withLock { tabs.values.first { $0.number == number } }
    }

    /// Works in another tab from now on. Nothing is brought forward for it: the browser's window may go on showing
    /// the tab it showed.
    func pick(tab name: String) -> Problem? {
        guard let tab = tab(named: name) else { return Problem("There's no tab \(name). tabs lists them (t1, t2…).") }
        guard attach(tab.id) != nil else { return .closed }
        lock.withLock {
            if current != tab.id { stamp += 1 }
            current = tab.id
        }
        onLeft?()
        return nil
    }

    func close(tab name: String) -> Problem? {
        let tab: Tab?
        if name.isEmpty {
            tab = lock.withLock { current.flatMap { tabs[$0] } }
        } else {
            tab = self.tab(named: name)
        }
        guard let tab else { return Problem(name.isEmpty ? "No tab is open." : "There's no tab \(name). tabs lists them (t1, t2…).") }
        guard lock.withLock({ tabs.count }) > 1 else { return Problem("That's your only tab: it stays (the browser goes when your run ends). open goes somewhere else in it.") }
        guard case .success = pipe.call("Target.closeTarget", ["targetId": tab.id]) else { return .closed }
        // The browser says it's gone a moment later: by then nothing works in it.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, lock.withLock({ tabs[tab.id] != nil }) { usleep(30_000) }
        return nil
    }

    // MARK: Going places

    /// Waits for the tab's page to be done loading and quiet for a moment, `bound` seconds at most. False: still loading.
    @discardableResult
    func settle(_ bound: TimeInterval, cancel: Acting.Cancel? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(bound)
        while true {
            let (busy, quiet): (Bool, TimeInterval) = lock.withLock {
                guard let target = current, let session = sessions[target] else { return (false, 1) }
                var all = [session]
                var at = 0
                while at < all.count {
                    all += (children[all[at]] ?? []).map(\.session)
                    at += 1
                }
                return (all.contains { !(loading[$0] ?? []).isEmpty }, Date().timeIntervalSince(activity))
            }
            if !busy, quiet >= 0.3 { return true }
            if Date() >= deadline || !alive || cancel?.stopped == true { return false }
            usleep(50_000)
        }
    }

    /// Opens `address` (checked already: RunBrowserRules.address): in the tab worked in, or a new one.
    func go(_ address: String, newTab: Bool, cancel: Acting.Cancel) -> Problem? {
        if newTab {
            guard alive else { return .closed }
            guard !cancel.stopped else { return Problem(ComputerUse.stoppedText) }
            guard let target = (try? pipe.call("Target.createTarget", ["url": "about:blank", "background": true]).get())?["targetId"] as? String,
                  attach(target) != nil else { return .closed }
            lock.withLock {
                mine.insert(target)
                if tabs[target] == nil { numbers += 1; tabs[target] = Tab(id: target, number: numbers) }
                current = target
                stamp += 1
            }
            onLeft?()
        }
        let session: String
        switch working() {
        case .failure(let problem): return problem
        case .success(let at): session = at.session
        }
        guard !cancel.stopped else { return Problem(ComputerUse.stoppedText) }
        lock.withLock { activity = Date() }
        switch pipe.call("Page.navigate", ["url": address], session: session, timeout: 30) {
        case .failure(let failure): return failure == .closed ? .closed : Problem("The page didn't open: \(failure.words)")
        case .success(let result):
            if let error = result["errorText"] as? String, !error.isEmpty, error != "net::ERR_ABORTED" {
                return Problem("The page didn't open (\(error)).")
            }
        }
        settle(12, cancel: cancel)
        return nil
    }

    /// back, forward or reload in the tab worked in.
    func history(_ action: String, cancel: Acting.Cancel) -> Problem? {
        let session: String
        switch working() {
        case .failure(let problem): return problem
        case .success(let at): session = at.session
        }
        guard !cancel.stopped else { return Problem(ComputerUse.stoppedText) }
        lock.withLock { activity = Date() }
        if action == "reload" {
            guard case .success = pipe.call("Page.reload", session: session) else { return .closed }
        } else {
            guard let history = try? pipe.call("Page.getNavigationHistory", session: session).get(),
                  let index = (history["currentIndex"] as? NSNumber)?.intValue, let entries = history["entries"] as? [[String: Any]] else { return .closed }
            let next = action == "back" ? index - 1 : index + 1
            guard entries.indices.contains(next), let id = (entries[next]["id"] as? NSNumber)?.intValue else {
                return Problem(action == "back" ? "There's no page to go back to." : "There's no page to go forward to.")
            }
            guard case .success = pipe.call("Page.navigateToHistoryEntry", ["entryId": id], session: session) else { return .closed }
        }
        usleep(120_000)
        settle(12, cancel: cancel)
        return nil
    }

    // MARK: Reading a page

    /// The page's frames as the browser lists them now, the page's own first, each after the one that holds it.
    private func frameList(_ session: String) -> [FrameAt]? {
        var out: [FrameAt] = []
        var index: [String: Int] = [:]
        func add(_ tree: [String: Any], session: String, parent: Int) {
            guard let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return }
            let at = out.count
            index[id] = at
            out.append(FrameAt(session: session, id: id, url: frame["url"] as? String ?? "", loader: frame["loaderId"] as? String ?? "", parent: parent))
            for child in tree["childFrames"] as? [[String: Any]] ?? [] { add(child, session: session, parent: at) }
        }
        guard let tree = (try? pipe.call("Page.getFrameTree", session: session).get())?["frameTree"] as? [String: Any] else { return nil }
        add(tree, session: session, parent: -1)
        // Frames in processes of their own, each under the frame that holds it (asked of its own session).
        var waiting: [String] = lock.withLock { (children[session] ?? []).map(\.session) }
        var seen = Set(waiting)
        var rounds = 0
        while !waiting.isEmpty, rounds < 40, out.count < 60 {
            rounds += 1
            let child = waiting.removeFirst()
            guard let tree = (try? pipe.call("Page.getFrameTree", session: child, timeout: 3).get())?["frameTree"] as? [String: Any],
                  let frame = tree["frame"] as? [String: Any] else { continue }
            guard let holder = (frame["parentId"] as? String).flatMap({ index[$0] }) else {
                // Its holder isn't listed yet (a frame inside another process's frame): once more, after the others.
                if rounds < 20 { waiting.append(child) }
                continue
            }
            add(tree, session: child, parent: holder)
            for inner in lock.withLock({ (children[child] ?? []).map(\.session) }) where seen.insert(inner).inserted { waiting.append(inner) }
        }
        return out
    }

    private enum Ran { case value(String), stale, failed(String) }

    /// Runs one of Petal's own functions in Petal's world of `frame`, and gives back its JSON.
    private func run(_ expression: String, in frame: FrameAt, gesture: Bool = false, timeout: TimeInterval = 10) -> Ran {
        var params: [String: Any] = ["expression": expression, "contextId": frame.context, "returnByValue": true]
        if gesture { params["userGesture"] = true }
        switch pipe.call("Runtime.evaluate", params, session: frame.session, timeout: timeout) {
        case .failure(.refused(let why)):
            // Its world went with its page.
            return why.contains("context") || why.contains("Context") ? .stale : .failed(why)
        case .failure(let failure): return .failed(failure.words)
        case .success(let result):
            if let problem = result["exceptionDetails"] as? [String: Any] {
                let text = (problem["exception"] as? [String: Any])?["description"] as? String ?? problem["text"] as? String ?? "the page refused"
                return .failed(UIMap.truncate(UIMap.tidy(text), 200))
            }
            guard let value = (result["result"] as? [String: Any])?["value"] as? String else { return .failed("the page gave no answer") }
            return .value(value)
        }
    }

    /// Petal's world in a frame (made once per page: asking again gives the same one).
    private func world(_ frame: inout FrameAt) -> Bool {
        guard let made = try? pipe.call("Page.createIsolatedWorld", ["frameId": frame.id, "worldName": RunBrowserScript.world], session: frame.session, timeout: 5).get(),
              let context = (made["executionContextId"] as? NSNumber)?.intValue else { return false }
        frame.context = context
        return true
    }

    /// Reads frame `at` and the frames inside it, in reading order.
    private func collect(_ at: Int, frames: inout [FrameAt], read: inout Int, depth: Int, more: inout Bool, title: inout String, deadline: Date) -> [PageNode] {
        guard read < 12, Date() < deadline, world(&frames[at]) else { return [] }
        read += 1
        guard let expression = RunBrowserScript.call(RunBrowserScript.collect, [4000, 60_000, 700]),
              case .value(let json) = run(expression, in: frames[at]), let got = BrowserOutline.nodes(fromJSON: json) else { return [] }
        frames[at].generation = got.generation
        if got.more { more = true }
        if at == 0 { title = got.title }
        // Which frame each of its frame elements holds: asked of the browser, by the element itself.
        var holds: [Int: Int] = [:]
        if depth < 3 {
            for child in frames.indices where frames[child].parent == at {
                guard let owner = (try? pipe.call("DOM.getFrameOwner", ["frameId": frames[child].id], session: frames[at].session, timeout: 3).get())?["backendNodeId"] as? NSNumber,
                      let object = ((try? pipe.call("DOM.resolveNode", ["backendNodeId": owner.intValue, "executionContextId": frames[at].context],
                                                    session: frames[at].session, timeout: 3).get())?["object"] as? [String: Any])?["objectId"] as? String,
                      let place = ((try? pipe.call("Runtime.callFunctionOn", ["objectId": object, "returnByValue": true,
                                                                              "functionDeclaration": "function(){ var S = globalThis.__petal; return S ? S.frames.indexOf(this) : -1; }"],
                                                   session: frames[at].session, timeout: 3).get())?["result"] as? [String: Any])?["value"] as? NSNumber,
                      place.intValue >= 0 else { continue }
                holds[place.intValue] = child
            }
        }
        var out: [PageNode] = []
        for var node in got.nodes {
            node.frame = at
            guard node.kind == "frame" else { out.append(node); continue }
            guard let child = holds[node.handle] else { continue }
            let inside = collect(child, frames: &frames, read: &read, depth: depth + 1, more: &more, title: &title, deadline: deadline)
            guard !inside.isEmpty else { continue }
            node.handle = child
            out.append(node)
            out += inside
        }
        return out
    }

    /// The tab's page as text, with ids for what can be used, through the vault's redaction; nothing is told while
    /// the vault can't be read. The ids last until the page changes or it's read again.
    func read(find: String) -> Result<Read, Problem> {
        let at: (target: String, session: String)
        switch working() {
        case .failure(let problem): return .failure(problem)
        case .success(let found): at = found
        }
        let stampBefore = lock.withLock { stamp }
        guard var frames = frameList(at.session), !frames.isEmpty else { return .failure(.closed) }
        var count = 0, more = false, title = ""
        let nodes = collect(0, frames: &frames, read: &count, depth: 0, more: &more, title: &title, deadline: Date().addingTimeInterval(8))
        guard count > 0 else { return .failure(Problem("The page couldn't be read (it may still be loading). Try wait, then read again.")) }
        let address = frames[0].url
        let addresses = frames.map(\.url)
        let joinBy = Date().addingTimeInterval(0.5)
        // Made again if the vault, or what Petal typed, changed while it was made: never told with a secret missing.
        let made = VaultIndex.settled { index -> (BrowserOutline, String, String)? in
            guard !index.unreadable else { return nil }
            let outline = BrowserOutline.make(nodes: nodes, frames: addresses, find: find, cut: more, redact: index.redacted, matches: index.matches,
                                              spans: index.spans, going: { Date() < joinBy })
            return (outline, index.redacted(title), index.redacted(address))
        }
        guard let made, let (outline, shownTitle, shownAddress) = made else {
            return .failure(Problem(VaultStore.unreadableText + " Petal can't check the page for your secrets, so it tells nothing of it. Try again in a moment."))
        }
        let (number, total): (Int, Int) = lock.withLock {
            // The page moved on while it was read: its ids would be another page's.
            if stamp == stampBefore { kept = Kept(outline: outline, frames: frames, target: at.target, stamp: stampBefore) }
            return (tabs[at.target]?.number ?? 1, tabs.count)
        }
        return .success(Read(title: shownTitle, address: shownAddress, tab: "t\(number)", tabs: total, text: outline.text, count: outline.count, left: outline.left))
    }

    /// What `id` stands for in the last read, while that read is still of the page the tab shows.
    func ref(_ id: String) -> Result<(ref: BrowserOutline.Ref, frame: FrameAt, kept: Kept), Problem> {
        guard alive else { return .failure(.closed) }
        return lock.withLock { () -> Result<(ref: BrowserOutline.Ref, frame: FrameAt, kept: Kept), Problem> in
            guard let kept, kept.target == current, kept.stamp == stamp else { return .failure(kept == nil ? Problem("Call petal_browser read first: ids come from it.") : .stale) }
            guard let ref = kept.outline.refs[id] else {
                return .failure(Problem("There's no \(id) in the last read (it listed b1 to b\(kept.outline.count)). Call petal_browser read again if the page changed."))
            }
            return .success((ref, kept.frames[ref.frame], kept))
        }
    }

    /// Whether the last read has these ids (for the vault: its fields are a page's).
    func has(_ ids: [String]) -> Bool {
        lock.withLock { ids.allSatisfy { kept?.outline.refs[$0] != nil } }
    }

    // MARK: Using a control

    /// One thing done to a control (RunBrowserScript.act): its answer, or why not.
    func act(_ id: String, _ op: String, _ arguments: [String: Any] = [:], gesture: Bool = false) -> Result<[String: Any], Problem> {
        switch ref(id) {
        case .failure(let problem): return .failure(problem)
        case .success(let found): return act(found.ref, in: found.frame, op, arguments, gesture: gesture)
        }
    }

    private func act(_ ref: BrowserOutline.Ref, in frame: FrameAt, _ op: String, _ arguments: [String: Any], gesture: Bool = false) -> Result<[String: Any], Problem> {
        var all = arguments
        all["gen"] = frame.generation
        guard let expression = RunBrowserScript.call(RunBrowserScript.act, [op, ref.handle, all]) else { return .failure(Problem("That couldn't be sent to the page.")) }
        lock.withLock { activity = Date() }
        switch run(expression, in: frame, gesture: gesture) {
        case .stale: return .failure(.stale)
        case .failed(let why): return .failure(alive ? Problem("The page didn't take it (\(why)).") : .closed)
        case .value(let json):
            guard let answer = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return .failure(Problem("The page gave no answer.")) }
            if answer["stale"] != nil { return .failure(.stale) }
            if answer["gone"] != nil { return .failure(Problem("That control isn't on the page any more. Call petal_browser read again.")) }
            return .success(answer)
        }
    }

    /// A key to whatever has the cursor in the tab worked in (the browser's own key event: nothing of the Mac's
    /// keyboard is used).
    func press(_ key: RunBrowserRules.Key, cancel: Acting.Cancel) -> Problem? {
        let session: String
        switch working() {
        case .failure(let problem): return problem
        case .success(let at): session = at.session
        }
        var down: [String: Any] = ["type": key.text == nil ? "rawKeyDown" : "keyDown", "key": key.key, "code": key.code,
                                   "windowsVirtualKeyCode": key.number, "nativeVirtualKeyCode": key.number]
        if let text = key.text { down["text"] = text }
        if key.shift { down["modifiers"] = 8 }
        var up = down
        up["type"] = "keyUp"
        up["text"] = nil
        guard !cancel.stopped else { return Problem(ComputerUse.stoppedText) }
        lock.withLock { activity = Date() }
        guard case .success = pipe.call("Input.dispatchKeyEvent", down, session: session) else { return .closed }
        _ = pipe.call("Input.dispatchKeyEvent", up, session: session)
        return nil
    }

    /// Where the tab worked in is now, asked of the page itself (the browser's own list of tabs hears a moment later):
    /// its address and title.
    func whereNow() -> (address: String, title: String)? {
        guard case .success(let at) = working(), var frames = frameList(at.session), !frames.isEmpty else { return nil }
        var title = ""
        if world(&frames[0]), case .value(let found) = run("String(document.title).slice(0, 300)", in: frames[0], timeout: 3) { title = UIMap.tidy(found) }
        return (frames[0].url, title)
    }

    /// Scrolls the page itself; where it is after ("at the top", "at the bottom", or between).
    func scroll(_ direction: String, cancel: Acting.Cancel) -> Result<String, Problem> {
        let session: String
        switch working() {
        case .failure(let problem): return .failure(problem)
        case .success(let at): session = at.session
        }
        guard var frames = frameList(session), !frames.isEmpty, world(&frames[0]),
              let expression = RunBrowserScript.call(RunBrowserScript.scroll, [direction]) else { return .failure(.closed) }
        guard !cancel.stopped else { return .failure(Problem(ComputerUse.stoppedText)) }
        guard case .value(let json) = run(expression, in: frames[0]),
              let answer = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return .failure(Problem("The page didn't scroll.")) }
        let y = (answer["y"] as? NSNumber)?.intValue ?? 0, most = (answer["most"] as? NSNumber)?.intValue ?? 0
        return .success(most <= 0 ? "The page fits: there's nothing to scroll." : y <= 0 ? "At the top." : y >= most - 2 ? "At the bottom." : "About \(Int(Double(y) / Double(most) * 100))% down.")
    }

    /// Waits for the page to settle, and for `words` to show in it when given, `seconds` at most.
    func wait(for words: String, seconds: TimeInterval, cancel: Acting.Cancel) -> Result<Bool, Problem> {
        let deadline = Date().addingTimeInterval(seconds)
        let settled = settle(min(seconds, 15), cancel: cancel)
        guard !words.isEmpty else { return .success(settled) }
        while true {
            guard !cancel.stopped else { return .failure(Problem(ComputerUse.stoppedText)) }
            let session: String
            switch working() {
            case .failure(let problem): return .failure(problem)
            case .success(let at): session = at.session
            }
            if var frames = frameList(session), let expression = RunBrowserScript.call(RunBrowserScript.has, [words]) {
                for index in frames.indices.prefix(12) where world(&frames[index]) {
                    if case .value(let found) = run(expression, in: frames[index], timeout: 3), found == "1" { return .success(true) }
                }
            }
            if Date() >= deadline { return .success(false) }
            usleep(150_000)
        }
    }

    // MARK: Where a field is, for the vault

    /// Where the field of `ref` is now, as the browser itself says (never the AI, never the page's own script): its
    /// frame's address, the tab's whole page's, and the browser's own record of the tab. nil: its frame is gone, or
    /// shows another document than the one read. In a browser Petal couldn't verify, the page is unverified.
    func place(_ ref: BrowserOutline.Ref, kept: Kept) -> Vault.Place? {
        guard alive, let session = lock.withLock({ sessions[kept.target] }), let now = frameList(session), let top = now.first else { return nil }
        let was = kept.frames[ref.frame]
        guard let frame = now.first(where: { $0.id == was.id && $0.session == was.session }), frame.loader == was.loader else { return nil }
        let info = (try? pipe.call("Target.getTargetInfo", ["targetId": kept.target], timeout: 5).get())?["targetInfo"] as? [String: Any]
        // The tab's page as it is now: another document in the tab is another page.
        return RunBrowserRules.place(frame: frame.url, top: top.url, tab: info?["url"] as? String, target: kept.target, loader: top.loader,
                                     trusted: verified, bundle: spec.bundle, name: spec.name)
    }

    /// What kind of field `ref` is now (asked of the page again: a field may have changed since it was read), and
    /// what it says of itself.
    func target(_ ref: BrowserOutline.Ref, kept: Kept) -> (target: Vault.Target, info: [String: Any])? {
        guard case .success(let info) = act(ref, in: kept.frames[ref.frame], "info", [:]) else { return nil }
        func flag(_ key: String) -> Bool { (info[key] as? NSNumber)?.intValue == 1 }
        return (Vault.Target(secure: flag("secure"), text: flag("text") && !flag("popup"), popup: flag("popup")), info)
    }

    /// The places and kinds of the fields named by `ids`, in order; nil when one isn't in the last read, or its page
    /// moved on.
    func places(_ ids: [String]) -> Result<(places: [Vault.Place], targets: [Vault.Target]), Problem> {
        var places: [Vault.Place] = [], targets: [Vault.Target] = []
        for id in ids {
            switch ref(id) {
            case .failure(let problem): return .failure(problem)
            case .success(let found):
                guard let place = place(found.ref, kept: found.kept), let target = target(found.ref, kept: found.kept) else { return .failure(.stale) }
                places.append(place)
                targets.append(target.target)
            }
        }
        return .success((places, targets))
    }

    /// Puts one vault value into the field `id`: only while the field is still in the document Petal decided on, at
    /// the address it decided on, still the kind of field it was. The value is set in that very element, in Petal's
    /// own world of the page: it can't land in another field, whatever has the cursor. Never the clipboard, never the
    /// Mac's keyboard; what went in is counted, never read back. nil: filled. Off the main thread.
    func fill(_ plan: VaultFillPlan, id: String, cancel: Acting.Cancel) -> String? {
        func stopped() -> String { cancel.buyEnded ? Acting.buyEndedText : ComputerUse.stoppedText }
        let found: (ref: BrowserOutline.Ref, frame: FrameAt, kept: Kept)
        switch ref(id) {
        case .failure(let problem): return problem.words + " Nothing was filled."
        case .success(let got): found = got
        }
        let card: Set<VaultField> = [.number, .securityCode, .expiry, .month, .year]
        // The same page as when Petal decided (payment info: the very page Buy was said on), asked of the browser now.
        func moved() -> String? {
            guard let now = place(found.ref, kept: found.kept) else {
                if plan.payment { cancel.endBuy() }
                return RunBrowserRules.stale + " Nothing was filled."
            }
            guard let why = Vault.moved(from: plan.place, to: now, samePage: card.contains(plan.field)) else { return nil }
            if plan.payment { cancel.endBuy() }
            return RunBrowsers.words(why)
        }
        if let why = moved() { return why }
        guard let kind = target(found.ref, kept: found.kept) else { return RunBrowserRules.stale + " Nothing was filled." }
        guard kind.target == plan.target else { return "That field changed since it was read; nothing was filled. Call petal_browser read again." }
        // What to put in: from the vault now (the AI never holds it), or what the person just typed into the card.
        let saved: VaultItem?
        if plan.given == nil {
            do { saved = try VaultStore.item(plan.itemID) } catch { return VaultStore.unreadableText + " Nothing was filled." }
        } else {
            saved = nil
        }
        var four: Bool?
        if [.year, .expiry].contains(plan.field), !plan.target.popup {
            let hints = ["ph", "lb", "tt"].map { kind.info[$0] as? String ?? "" }
            four = Vault.fourDigitYear(plan.field, format: plan.yearFormat, hints: hints, maxLength: (kind.info["ml"] as? NSNumber)?.intValue)
        }
        // The item as it was when Petal planned the fill (and the person said Buy on it), not one edited since.
        if let saved, !Vault.sameRevision(plan.revision, saved) { return Vault.changedText }
        guard let text = plan.given.map({ Vault.typed(plan.field, $0) }) ?? saved.flatMap({ Vault.text($0, plan.field, fourDigitYear: four) }),
              !text.isEmpty else { return "That isn't in the vault anymore." }
        guard !cancel.stopped else { return stopped() }
        // Hidden from the AI before it goes in, saved in the vault or not: in everything Petal reads, for as long as
        // Petal runs.
        if plan.field.isSecret { VaultIndex.remember(Vault.secrets(plan.field, text)) }
        var arguments: [String: Any] = ["secret": plan.field.isSecret, "secure": plan.target.secure]
        let op: String
        if plan.target.popup {
            let titles = kind.info["opts"] as? [String] ?? [], values = kind.info["vals"] as? [String] ?? []
            let year = plan.field == .year ? saved.map { $0[.expiry] } : nil
            let pick: ([String]) -> Int? = { options in
                if plan.field == .month { return Vault.pickMonth(text, from: options) }
                return year.flatMap { Vault.pickYear($0, from: options) } ?? Vault.pick(text, from: options)
            }
            guard let index = pick(titles) ?? pick(values) else {
                return "That menu has no choice that matches; nothing was picked."
            }
            arguments["index"] = index
            op = "select"
        } else {
            arguments["text"] = text
            arguments["replace"] = true
            op = "type"
        }
        // Right before it goes: not stopped, steered or past its Buy, and still the page Petal decided on.
        if let why = moved() { return why }
        guard !cancel.stopped else { return stopped() }
        let answer: [String: Any]
        switch act(found.ref, in: found.frame, op, arguments) {
        case .failure(let problem): return problem.words + " Nothing was filled."
        case .success(let got): answer = got
        }
        if answer["changed"] != nil { return "That field changed since it was read; nothing was filled. Call petal_browser read again." }
        if answer["nofit"] != nil {
            return plan.field == .number ? "The card number didn't fit in that field: it holds fewer digits than the card has. Ask the person to check it."
                : plan.field == .securityCode ? "The security code didn't fit in that field. Ask the person to check it."
                : "That field is too short for it; nothing was filled."
        }
        if answer["off"] != nil { return "That field can't be typed into right now (it's greyed out or read-only); nothing was filled." }
        guard answer["ok"] != nil else { return "The page didn't take it; nothing was filled." }
        if plan.field == .number || plan.field == .securityCode {
            let digits = (answer["digits"] as? NSNumber)?.intValue, count = (answer["len"] as? NSNumber)?.intValue
            let wanted = text.filter { UIMap.SecretIndex.digit($0) != nil }.count
            if let digits, digits < wanted, (count ?? 0) < text.count {
                return plan.field == .number ? "The card number didn't fit in that field: it holds fewer digits than the card has. Ask the person to check it."
                    : "The security code didn't fit in that field. Ask the person to check it."
            }
        }
        if plan.submit {
            guard !cancel.stopped else { return stopped() }
            if let why = moved() { return "It was filled, not sent: " + why }
            if case .failure(let problem) = act(found.ref, in: found.frame, "submit", [:], gesture: true) { return "It was filled, not sent: " + problem.words }
            usleep(120_000)
            settle(8, cancel: cancel)
        }
        return nil
    }
}

extension RunBrowser {
    // MARK: For checks

    /// The session of the tab worked in (a check talks to the browser itself to see what a tool did).
    var checkSession: String? { lock.withLock { current.flatMap { sessions[$0] } } }

    /// What an expression gives in the page's own world of the tab worked in, as text: how a check sees what a
    /// fill put in, which no tool ever tells.
    func checkEvaluate(_ expression: String) -> String? {
        guard let session = checkSession,
              let result = try? pipe.call("Runtime.evaluate", ["expression": expression, "returnByValue": true], session: session, timeout: 5).get(),
              let value = (result["result"] as? [String: Any])?["value"] else { return nil }
        return value as? String ?? "\(value)"
    }

    /// Where the browser says its window is (the window server's coordinates), for a check to print.
    func checkWindowBounds() -> CGRect? {
        guard let target = lock.withLock({ current }),
              let found = try? pipe.call("Browser.getWindowForTarget", ["targetId": target], timeout: 5).get(),
              let box = found["bounds"] as? [String: Any] else { return nil }
        func value(_ key: String) -> CGFloat { CGFloat((box[key] as? NSNumber)?.doubleValue ?? 0) }
        return CGRect(x: value("left"), y: value("top"), width: value("width"), height: value("height"))
    }
}

/// Every run's browser: which group has one, starting one when a run first uses `petal_browser` (its display first),
/// ending it with the run's display, and what's left of browsers from a Petal that crashed.
///
/// A run's browser is the same app as the person's own, as a second process. So Petal never takes it for theirs: the
/// dock, window lists, previews and the tools that name running apps all leave out a process Petal started for a run
/// (`RunBrowsers.isRun`, `NSWorkspace.personsApplications`).
@MainActor
final class RunBrowsers {
    private var browsers: [String: RunBrowser] = [:]
    private var starting: [String: [(Result<RunBrowser, RunBrowser.Problem>) -> Void]] = [:]
    /// Which installed browser a run gets (`setting`: `runBrowser`), off the main thread. A check hands in its own.
    var finder: @Sendable (_ setting: String) -> RunBrowser.Spec? = { RunBrowsers.find(setting: $0) }
    private var watching: NSObjectProtocol?
    /// The app the person last had in front that isn't a run's browser.
    private var lastFront: pid_t = 0

    nonisolated static let queue = DispatchQueue(label: "petal.runbrowsers", qos: .userInitiated)
    /// What a reply is allowed when the person lets it use a browser of its own (Assist.ask's kind, and the app's
    /// place in the reply's grants).
    nonisolated static let kind = "browser"

    var app: PetalApp { PetalApp.shared }

    // MARK: Whose processes

    /// `pid` is a browser Petal started for a run: never one of the person's apps (RunApps keeps which).
    nonisolated static func isRun(_ pid: pid_t) -> Bool { RunApps.isRun(pid) }

    /// A run's browser of this app is going now (the person's own copy needs to be opened as a new one).
    nonisolated static func running(bundle: String) -> Bool { RunApps.running(bundle: bundle) }

    /// From before it has a window until it's ended: a process Petal started for a run is never the person's app.
    nonisolated static func register(_ pid: pid_t, bundle: String) { RunApps.register(pid, bundle: bundle) }
    nonisolated static func forget(_ pid: pid_t) { RunApps.forget(pid) }

    // MARK: Folders

    /// Where every run's profile is: Petal's own folder, never the person's browser's.
    nonisolated static var root: String { Config.supportFolder.appending(path: RunBrowserRules.folder).path }

    /// Removes a run's profile folder: only ever a folder right inside `root` by a plain name.
    nonisolated static func removeProfile(_ path: String) {
        guard RunBrowserRules.removable(path, root: root) else { return }
        for attempt in 0..<5 {
            if (try? FileManager.default.removeItem(atPath: path)) != nil || !FileManager.default.fileExists(atPath: path) { return }
            if attempt < 4 { usleep(150_000) }
        }
    }

    /// The vault's and the tools' words, for a page of the run's browser: its ids come from petal_browser read.
    nonisolated static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "Call petal_ui again", with: "Call petal_browser read again")
            .replacingOccurrences(of: "id from petal_ui", with: "id from petal_browser read")
            .replacingOccurrences(of: "since petal_ui", with: "since petal_browser read")
    }

    // MARK: Which browser

    /// The browser a run gets: installed, one Petal knows, its code signed by its maker (checked here on the app, and
    /// again on the running process whenever the vault asks). Off the main thread: it asks Launch Services and reads
    /// the app's signature.
    nonisolated static func find(setting: String) -> RunBrowser.Spec? {
        var found: [String: URL] = [:]
        for known in RunBrowserRules.browsers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundle), signed(url, by: known) else { continue }
            found[known.bundle] = url
        }
        guard !found.isEmpty else { return nil }
        let running = Set(NSWorkspace.shared.personsApplications.compactMap(\.bundleIdentifier))
        let standard = URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard let pick = RunBrowserRules.pick(installed: Array(found.keys), running: running, standard: standard, setting: setting),
              let url = found[pick.bundle], let executable = Bundle(url: url)?.executableURL?.path else { return nil }
        let bundle = pick.bundle
        return RunBrowser.Spec(bundle: bundle, name: pick.name, executable: executable, verify: { VaultReader.isBrowser(pid: $0, bundle: bundle) })
    }

    /// The app at `url` is that browser, signed by its maker (its code's signature, not every file in it: the running
    /// process is checked again).
    nonisolated private static func signed(_ url: URL, by known: RunBrowserRules.Known) -> Bool {
        guard !known.bundle.contains("\""), known.team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and identifier \"\(known.bundle)\" and certificate leaf[subject.OU] = \"\(known.team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }

    // MARK: Getting one

    /// The caller's run's browser, when it has one going.
    func browser(for caller: String?) -> RunBrowser? {
        guard let caller, let browser = browsers[app.displays.group(of: caller)], browser.alive else { return nil }
        return browser
    }

    /// The run's browser: the one it has, or a new one on its display (which it gets first, or waits its turn for).
    /// `done` hears on the main thread.
    func need(_ caller: String, label: String, done: @escaping (Result<RunBrowser, RunBrowser.Problem>) -> Void) {
        let group = app.displays.group(of: caller)
        if let browser = browsers[group] {
            if browser.alive { return done(.success(browser)) }
            ended(group)
        }
        guard app.config.bool("runDisplays") else { return done(.failure(.init(RunBrowserRules.off))) }
        app.displays.need(caller, label: label) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let why):
                let none = " A browser of your own needs one. Use your own web tools, or the person's own windows (petal_look, petal_ui)."
                switch why {
                case .off: done(.failure(.init(RunBrowserRules.off)))
                case .unavailable: done(.failure(.init("This Mac can't make a hidden display for Petal AI (macOS didn't allow it)." + none)))
                case .placing: done(.failure(.init("macOS wouldn't keep a hidden display out of the pointer's way, so Petal made none." + none)))
                case .ended: done(.failure(.init(why.words)))
                }
            case .success(let display): self.start(group, caller: caller, display: display, done)
            }
        }
    }

    private func start(_ group: String, caller: String, display: RunDisplays.Display, _ done: @escaping (Result<RunBrowser, RunBrowser.Problem>) -> Void) {
        if let browser = browsers[group], browser.alive { return done(.success(browser)) }
        if starting[group] != nil { starting[group]?.append(done); return }
        starting[group] = [done]
        let finder = self.finder, setting = app.config.string("runBrowser")
        let frame = RunBrowser.windowFrame(on: display.frame)
        let profile = (Self.root as NSString).appendingPathComponent(RunBrowserRules.folderName(group: group, nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()))
        watch()
        Self.queue.async {
            let result: Result<RunBrowser, RunBrowser.Problem>
            if let spec = finder(setting) {
                result = RunBrowser.launch(spec: spec, group: group, profile: profile, frame: frame)
                // The person's from before it has a window: never listed as theirs.
                if case .success(let browser) = result { Self.register(browser.pid, bundle: spec.bundle) }
            } else {
                result = .failure(.init(RunBrowserRules.none))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let waiting = self.starting.removeValue(forKey: group) ?? []
                    var answer = result
                    if case .success(let browser) = result {
                        // Its display went while it started (the run ended, hidden displays were turned off): it goes too.
                        if self.app.displays.displays[group]?.ready == true, self.app.config.bool("runDisplays") {
                            self.browsers[group] = browser
                            self.adopt(browser, group: group, caller: caller)
                        } else {
                            Self.forget(browser.pid)
                            browser.end()
                            answer = .failure(.init(RunDisplays.Failure.ended.words))
                        }
                    }
                    for waiter in waiting { waiter(answer) }
                }
            }
        }
    }

    /// A browser that just started: a Buy said in it ends when its page moves on, and its window is the run's own
    /// (Show me brings it to the person's screen with the rest).
    private func adopt(_ browser: RunBrowser, group: String, caller: String) {
        let window = browser.window
        browser.onLeft = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.app.assist.computer.seen([], window: window) } }
        }
        app.assist.did("Started \(named: browser.spec.name, else: "a browser") for a run, on a display of its own")
        guard !browser.spec.headless, Windows.trusted else { return }
        let pid = browser.pid
        RunDisplays.queue.async {
            var found: [(window: CGWindowID, pid: pid_t, element: AXUIElement)] = []
            let deadline = Date().addingTimeInterval(5)
            while found.isEmpty, Date() < deadline, browser.alive {
                for number in RunDisplays.windowNumbers(pid: pid).keys {
                    if let element = RunDisplays.element(number, pid: pid) { found.append((number, pid, element)) }
                }
                if found.isEmpty { usleep(200_000) }
            }
            guard !found.isEmpty else { return }
            nonisolated(unsafe) let tracked = found
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.browsers[group] === browser else { return }
                    self.app.displays.track(tracked, for: caller, bare: false)
                }
            }
        }
    }

    // MARK: Ending

    private func ended(_ group: String) {
        guard let browser = browsers.removeValue(forKey: group) else { return }
        Self.forget(browser.pid)
        app.assist.computer.seen([], window: browser.window)
        browser.end()
        if browsers.isEmpty, starting.isEmpty { unwatch() }
    }

    /// A run's display is going (its run ended: done, failed, stopped, paused, its note thrown away; or hidden
    /// displays were turned off): its browser ends first, so its window is never left to land on the person's screen.
    func displayGoing(_ group: String) { ended(group) }

    /// Petal is quitting: every run's browser ends now, and its profile goes before Petal does.
    func quit() {
        for (group, browser) in browsers {
            Self.forget(browser.pid)
            browser.end(wait: 1.5)
            browsers[group] = nil
        }
        unwatch()
    }

    // MARK: Never in front by itself

    /// While a run has a browser: if it comes to the front by itself (a browser may do that as it starts), the app
    /// the person was using gets the front back. Never once they took its window with Show me.
    private func watch() {
        guard watching == nil, !Headless.on else { return }
        lastFront = NSWorkspace.shared.frontmostApplication.flatMap { Self.isRun($0.processIdentifier) ? nil : $0.processIdentifier } ?? 0
        watching = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(running) }
        }
    }

    private func unwatch() {
        if let watching { NSWorkspace.shared.notificationCenter.removeObserver(watching) }
        watching = nil
    }

    private func activated(_ running: NSRunningApplication?) {
        guard let running else { return }
        let pid = running.processIdentifier
        guard Self.isRun(pid) else { lastFront = pid; return }
        // The person asked to see it (Show me): it's theirs to use.
        let shown = app.displays.displays.values.contains { display in display.windows.values.contains { $0.pid == pid && $0.shown } }
        guard !shown, lastFront > 0, let back = NSRunningApplication(processIdentifier: lastFront), !back.isTerminated else { return }
        back.activate()
    }

    // MARK: What a crash left

    /// At launch: browsers a Petal that crashed (or was killed) left running are ended, and every profile folder
    /// nobody holds is removed. They're found by the profile folder they were started with. Off the main thread.
    func sweep() {
        guard !Headless.on else { return }
        let mine = Set(browsers.values.map(\.profile))
        Self.queue.async { Self.sweep(root: Self.root, mine: mine) }
    }

    /// Returns what it ended and removed (for a check).
    @discardableResult
    nonisolated static func sweep(root: String, mine: Set<String>) -> (ended: [Int32], removed: [String]) {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        // Nothing of a run's was ever there: no process is looked at.
        guard FileManager.default.fileExists(atPath: root) else { return ([], []) }
        let plan = RunBrowserRules.leftovers(processes: processes(), folders: folders, root: root, mine: mine)
        for pid in plan.end { Darwin.kill(pid, SIGKILL) }
        if !plan.end.isEmpty { usleep(400_000) }
        for path in plan.remove where RunBrowserRules.removable(path, root: root) {
            for attempt in 0..<4 {
                if (try? FileManager.default.removeItem(atPath: path)) != nil || !FileManager.default.fileExists(atPath: path) { break }
                if attempt < 3 { usleep(200_000) }
            }
        }
        return (plan.end, plan.remove.filter { !FileManager.default.fileExists(atPath: $0) })
    }

    /// Every process of the person's with what it was started with.
    nonisolated static func processes() -> [(pid: Int32, arguments: [String])] {
        let room = proc_listallpids(nil, 0)
        guard room > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(room) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let me = getpid()
        var out: [(pid: Int32, arguments: [String])] = []
        for pid in pids.prefix(Int(count)) where pid > 1 && pid != me {
            if let arguments = PetalProcess.arguments(of: pid) { out.append((pid, arguments)) }
        }
        return out
    }

    // MARK: For checks

    var count: Int { browsers.count }
}
