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
    /// `spawned`: called with the child's pid the moment it exists, before anything else is done with it;
    /// `exited`: called once the process is gone, however it went.
    static func start(executable: String, arguments: [String], spawned: ((pid_t) -> Void)? = nil, exited: (@Sendable (pid_t) -> Void)? = nil) -> BrowserPipe? {
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
        if status == 0, pid > 0 { spawned?(pid) }
        close(childRead)
        close(childWrite)
        guard status == 0, pid > 0 else {
            close(parentWrite)
            close(parentRead)
            return nil
        }
        let made = BrowserPipe(pid: pid, writeFD: parentWrite, readFD: parentRead)
        made.exitedHandler = exited
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

    private var exitedHandler: (@Sendable (pid_t) -> Void)?

    private func reap() {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        lock.withLock { gone = true }
        exitedHandler?(pid)
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
        /// Whose the document is, as the browser's inspector gives it for the frame's own script context
        /// ("https://example.com"; "://" for an origin that is nobody's: a sandboxed document, a data: page). Never
        /// derived from its address: a sandboxed document at a site's address isn't the site's, and a frame with no
        /// address of its own is the site's that made it. Empty: the browser didn't say.
        var origin = ""
        var loader: String
        var parent: Int
        var context = 0
        /// The read (`collect`) its controls' numbers came from.
        var generation = 0
    }

    /// A field as it was when a fill was planned for it: the very element (its number in its frame's read), the
    /// frame's document and Petal's world in it, the tab and how often its page had become another. A fill carries
    /// this from the plan, through whatever card the person answers, to the write: never an id looked up again, which
    /// a later read may have given to another element.
    struct Bound {
        var ref: BrowserOutline.Ref
        var frame: FrameAt
        var target: String
        var stamp: Int
    }

    /// One browser being started for a run, so every ending of the run can end it: before it exists (nothing is
    /// started), once its process exists (it's ended, and its profile goes with it), or as it finishes (thrown away).
    final class Launch: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var pipe: BrowserPipe?

        var cancelled: Bool { lock.withLock { stopped } }

        /// The child exists. False: the launch was cancelled meanwhile, and the child is the caller's to end.
        func started(_ pipe: BrowserPipe) -> Bool {
            lock.withLock {
                guard !stopped else { return false }
                self.pipe = pipe
                return true
            }
        }

        /// Ends it, wherever it is: nothing more is started, and a browser already started is ended now (what waits
        /// on it hears it closed, and the launch removes its profile).
        func cancel() {
            let running: BrowserPipe? = lock.withLock {
                stopped = true
                return pipe
            }
            running?.kill()
        }
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
    /// The clipboard a page's own copy would land on: the person's (a check hands in one of its own).
    var clipboard: NSPasteboard = .general
    /// A press went to a page (a click, a check, a submit, a key), on the browser's queue: with the clipboard's
    /// count from right before it, for whoever watches what the page copies on it (RunBrowsers).
    var onPress: (@Sendable (Acting.CopyMark) -> Void)?

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
    /// Counts every time a tab's page moved on in any way Petal heard of (another document, another address of the
    /// same document, another tab picked): a write decided before isn't made after.
    private var moves = 0
    /// Each frame's origin as the browser's inspector reports it, while one session is being asked.
    private var reported: [String: [String: String]] = [:]
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
    /// `launch`: lets the run's ending end it at any point (RunBrowsers); cancelled, nothing is started, or what was
    /// started is ended here. The process is a run's (RunApps) from the moment it exists until it's gone, so nothing
    /// ever takes it for one of the person's apps, not even while it starts.
    static func launch(spec: Spec, group: String, profile: String, frame: CGRect?, launch: Launch? = nil) -> Result<RunBrowser, Problem> {
        let ended = Problem(RunDisplays.Failure.ended.words)
        if launch?.cancelled == true { return .failure(ended) }
        do {
            try FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(Problem("Petal couldn't make a folder for the browser's profile."))
        }
        let arguments = RunBrowserRules.arguments(profile: profile, frame: spec.headless ? nil : frame) + spec.extra
        let bundle = spec.bundle
        let started = BrowserPipe.start(executable: spec.executable, arguments: arguments,
                                        spawned: { RunApps.register($0, bundle: bundle) }, exited: { RunApps.forget($0) })
        guard let pipe = started else {
            RunBrowsers.removeProfile(profile)
            return .failure(Problem("\(spec.name) couldn't be started for a run."))
        }
        let browser = RunBrowser(spec: spec, group: group, profile: profile, pipe: pipe)
        // Cancelled while it was being started: ended at once, its profile with it.
        if let launch, !launch.started(pipe) {
            browser.end(wait: 2)
            return .failure(ended)
        }
        if let problem = browser.open(frame: spec.headless ? nil : frame) {
            browser.end(wait: 2)
            return .failure(launch?.cancelled == true ? ended : problem)
        }
        if launch?.cancelled == true {
            browser.end(wait: 2)
            return .failure(ended)
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
        // No page puts anything on the person's clipboard by itself, or reads it: refused for every site, before
        // any page loads. A browser that won't take that is ended.
        for permission in RunBrowserRules.refused {
            guard case .success = pipe.call("Browser.setPermission", RunBrowserRules.refusal(permission)) else {
                return Problem("\(spec.name) wouldn't keep its pages off the clipboard, so it was ended.")
            }
        }
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
                    if info["openerId"] != nil, !mine.contains(id) { remember("The page opened a new tab (t\(numbers)). tab switches to it.") }
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
                moves += 1
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
        case "Runtime.executionContextCreated":
            // Asked for while a place is read (`origins`): each frame's own context, with whose it is.
            guard let session, let context = params["context"] as? [String: Any], let aux = context["auxData"] as? [String: Any],
                  (aux["isDefault"] as? NSNumber)?.boolValue == true, let frame = aux["frameId"] as? String else { return }
            let origin = context["origin"] as? String ?? ""
            lock.withLock { if reported[session] != nil { reported[session]?[frame] = origin } }
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
                moves += 1
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
                lock.withLock { remember("The page showed a message\(said.isEmpty ? "" : ": “\(said)”") (\(accept ? "closed" : "answered Cancel")).") }
            }
        case "Page.fileChooserOpened":
            lock.withLock { remember("The page asked for a file to upload: choosing a file isn't built in a run's browser, so none was given.") }
        case "Browser.downloadWillBegin":
            let note = RunBrowserRules.downloadRefused(params["suggestedFilename"] as? String ?? "", from: params["url"] as? String ?? "")
            lock.withLock { remember(note) }
        case "Inspector.targetCrashed":
            lock.withLock { remember("The page crashed. reload loads it again.") }
        default: onOther?(method, params, session)
        }
    }

    /// Anything else the browser says (a check's own conversation with it), on the reading thread.
    var onOther: ((_ method: String, _ params: [String: Any], _ session: String?) -> Void)?

    /// Keeps one thing that happened by itself, for the next answer (called with the lock held). A page that keeps at
    /// it (a message in a loop) never makes an answer long: a dozen are told, the rest counted.
    private func remember(_ note: String) {
        if happened.count < 12 { happened.append(UIMap.truncate(note, 500)) } else { unsaid += 1 }
    }

    private var unsaid = 0

    /// Something Petal did about the page by itself, for the next answer.
    func say(_ note: String) { lock.withLock { remember(note) } }

    /// What happened by itself since this was last asked (a message closed, a download refused, a new tab), once.
    func notes() -> [String] {
        lock.withLock {
            var list = happened
            if unsaid > 0 { list.append("And \(unsaid) more like these.") }
            happened = []
            unsaid = 0
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
            moves += 1
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
                moves += 1
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
    /// `withOrigins`: each frame also with whose it is (asked only where the vault needs it).
    private func frameList(_ session: String, withOrigins: Bool = false) -> [FrameAt]? {
        var out: [FrameAt] = []
        var index: [String: Int] = [:]
        var whose: [String: [String: String]] = [:]
        func add(_ tree: [String: Any], session: String, parent: Int) {
            guard let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return }
            let at = out.count
            index[id] = at
            var one = FrameAt(session: session, id: id, url: frame["url"] as? String ?? "", loader: frame["loaderId"] as? String ?? "", parent: parent)
            one.origin = whose[session]?[id] ?? ""
            out.append(one)
            for child in tree["childFrames"] as? [[String: Any]] ?? [] { add(child, session: session, parent: at) }
        }
        guard let tree = (try? pipe.call("Page.getFrameTree", session: session).get())?["frameTree"] as? [String: Any] else { return nil }
        if withOrigins { whose[session] = origins(session) }
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
            if withOrigins { whose[child] = origins(child) }
            add(tree, session: child, parent: holder)
            for inner in lock.withLock({ (children[child] ?? []).map(\.session) }) where seen.insert(inner).inserted { waiting.append(inner) }
        }
        return out
    }

    /// Whose each frame of a session is: the origin the browser's inspector reports for the frame's own script
    /// context. Nothing is run in the page for it: turning the inspector's runtime on makes it list every context
    /// there is, each with its origin, before it answers; it's turned off again at once (a page's own chatter is none
    /// of Petal's business). A frame it doesn't list has no origin Petal knows.
    private func origins(_ session: String) -> [String: String] {
        lock.withLock { reported[session] = [:] }
        _ = pipe.call("Runtime.enable", session: session, timeout: 5)
        _ = pipe.call("Runtime.disable", session: session, timeout: 5)
        return lock.withLock { reported.removeValue(forKey: session) ?? [:] }
    }

    private enum Ran { case value(String), stale, failed(String) }

    /// Runs one of Petal's own functions in Petal's world of `frame`, and gives back its JSON.
    private func run(_ expression: String, in frame: FrameAt, gesture: Bool = false, timeout: TimeInterval = 10) -> Ran {
        var params: [String: Any] = ["expression": expression, "contextId": frame.context, "returnByValue": true]
        if gesture { params["userGesture"] = true }
        // A press lets the page copy: the clipboard's count from before it, for the watch after.
        let mark = gesture ? Acting.CopyMark.now(clipboard) : nil
        defer { if let mark { onPress?(mark) } }
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

    /// The fields these ids stand for in the last read, bound as they are now (for the vault: a fill is planned for
    /// these very elements, whatever is read later). nil: one of them isn't in the last read, or that read is of a
    /// page the tab no longer shows.
    func bind(_ ids: [String]) -> [Bound]? {
        lock.withLock { () -> [Bound]? in
            guard let kept, kept.target == current, kept.stamp == stamp else { return nil }
            var out: [Bound] = []
            for id in ids {
                guard let ref = kept.outline.refs[id] else { return nil }
                out.append(Bound(ref: ref, frame: kept.frames[ref.frame], target: kept.target, stamp: kept.stamp))
            }
            return out
        }
    }

    /// The tab still shows the page a field was bound on (the same tab worked in, not become another page since).
    private func holds(_ bound: Bound) -> Bool {
        alive && lock.withLock { current == bound.target && stamp == bound.stamp }
    }

    // MARK: Using a control

    /// One thing done to a control (RunBrowserScript.act): its answer, or why not.
    /// `bound`: the control as it was bound when the call came in (before any card the person had to answer); with
    /// it, the id is never looked up again, and a page read again since gets nothing done.
    func act(_ id: String, bound: Bound? = nil, _ op: String, _ arguments: [String: Any] = [:], gesture: Bool = false) -> Result<[String: Any], Problem> {
        if let bound {
            guard holds(bound) else { return .failure(alive ? .stale : .closed) }
            return act(bound.ref, in: bound.frame, op, arguments, gesture: gesture)
        }
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
        // A key is a press to the page too.
        let mark = Acting.CopyMark.now(clipboard)
        defer { onPress?(mark) }
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

    /// Where a bound field is now, as the browser itself says (never the AI, never the page's own script): its
    /// frame's document and the tab's whole page, each with its address and whose it is, and the browser's own record
    /// of the tab. nil: the tab moved on, or the field's frame is gone or shows another document than the one bound.
    /// In a browser Petal couldn't verify, the page is unverified.
    private func spot(_ bound: Bound) -> (place: Vault.Place, frame: FrameAt, top: FrameAt)? {
        guard holds(bound), let session = lock.withLock({ sessions[bound.target] }), let now = frameList(session, withOrigins: true),
              let top = now.first else { return nil }
        let was = bound.frame
        guard let frame = now.first(where: { $0.id == was.id && $0.session == was.session }), frame.loader == was.loader else { return nil }
        let info = (try? pipe.call("Target.getTargetInfo", ["targetId": bound.target], timeout: 5).get())?["targetInfo"] as? [String: Any]
        // The tab's page as it is now: another document in the tab is another page.
        let place = RunBrowserRules.place(frame: RunBrowserRules.Document(url: frame.url, origin: frame.origin),
                                          top: RunBrowserRules.Document(url: top.url, origin: top.origin),
                                          tab: info?["url"] as? String, target: bound.target, loader: top.loader,
                                          trusted: verified, bundle: spec.bundle, name: spec.name)
        return (place, frame, top)
    }

    func place(_ bound: Bound) -> Vault.Place? { spot(bound)?.place }

    /// What kind of field a bound field is now (asked of the page again: a field may have changed since it was
    /// read), and what it says of itself. nil: its read was replaced, or it left the page.
    func target(_ bound: Bound) -> (target: Vault.Target, info: [String: Any])? {
        guard holds(bound), case .success(let info) = act(bound.ref, in: bound.frame, "info", [:]) else { return nil }
        func flag(_ key: String) -> Bool { (info[key] as? NSNumber)?.intValue == 1 }
        return (Vault.Target(secure: flag("secure"), text: flag("text") && !flag("popup"), popup: flag("popup")), info)
    }

    /// The places and kinds of bound fields, in order; a problem when one's page moved on or was read again.
    func places(_ fields: [Bound]) -> Result<(places: [Vault.Place], targets: [Vault.Target]), Problem> {
        var places: [Vault.Place] = [], targets: [Vault.Target] = []
        for field in fields {
            guard let place = place(field), let target = target(field) else { return .failure(.stale) }
            places.append(place)
            targets.append(target.target)
        }
        return .success((places, targets))
    }

    /// Puts one vault value into a bound field: the very element the fill was planned for, only while it's still in
    /// the document Petal decided on, at the address it decided on, still the kind of field it was. A field read
    /// again since (its id may be another element's now), gone, or in a document that became another gets nothing.
    /// The value is set in that element, in Petal's own world of the page: it can't land in another field, whatever
    /// has the cursor. Never the clipboard, never the Mac's keyboard; what went in is counted, never read back.
    ///
    /// The last checks are in two places, so no code of the page's runs between them and the write: here, right
    /// before the write is sent (not stopped, the page asked of the browser once more, and no word of the page
    /// moving on come in since), and in the page itself, inside the very call that writes, after the one step the
    /// page can hook (the field taking the cursor) and immediately before the value is set (RunBrowserScript.act).
    /// nil: filled. Off the main thread.
    func fill(_ plan: VaultFillPlan, field: Bound, cancel: Acting.Cancel) -> String? {
        func stopped() -> String { cancel.buyEnded ? Acting.buyEndedText : ComputerUse.stoppedText }
        let changed = RunBrowserRules.stale + " Nothing was filled."
        let card: Set<VaultField> = [.number, .securityCode, .expiry, .month, .year]
        var at = "", top = ""
        // The same page as when Petal decided (payment info: the very page Buy was said on), asked of the browser now.
        func moved() -> String? {
            guard let now = spot(field) else {
                if plan.payment { cancel.endBuy() }
                return changed
            }
            at = now.frame.url
            top = now.top.url
            guard let why = Vault.moved(from: plan.place, to: now.place, samePage: card.contains(plan.field)) else { return nil }
            if plan.payment { cancel.endBuy() }
            return RunBrowsers.words(why)
        }
        if let why = moved() { return why }
        guard let kind = target(field) else { return changed }
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
        var arguments: [String: Any] = ["vault": true, "secret": plan.field.isSecret, "secure": plan.target.secure]
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
        // Right before it goes: still the page Petal decided on (asked once more), not stopped, steered or past its
        // Buy, and nothing heard of the page moving on while that was asked. The write then checks its own document's
        // address, and the tab's where it can see it, once more in the page, immediately before the value is set.
        let heard = lock.withLock { moves }
        if let why = moved() { return why }
        guard !cancel.stopped else { return stopped() }
        guard lock.withLock({ moves }) == heard else {
            if plan.payment { cancel.endBuy() }
            return changed
        }
        arguments["at"] = at
        arguments["top"] = top
        let answer: [String: Any]
        switch act(field.ref, in: field.frame, op, arguments) {
        case .failure(let problem): return problem.words + " Nothing was filled."
        case .success(let got): answer = got
        }
        if answer["moved"] != nil {
            // The page moved on as the field took the cursor: nothing was written, and a Buy said on it is over.
            if plan.payment { cancel.endBuy() }
            return changed
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
            if case .failure(let problem) = act(field.ref, in: field.frame, "submit", [:], gesture: true) { return "It was filled, not sent: " + problem.words }
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
    /// A browser being started for a group: the launch itself (so the run's ending can end it), the very display it
    /// was started for, and who waits for it.
    private struct Starting {
        let launch: RunBrowser.Launch
        let display: RunDisplays.Display
        var waiters: [(Result<RunBrowser, RunBrowser.Problem>) -> Void]
    }

    private var starting: [String: Starting] = [:]
    /// Which installed browser a run gets (`setting`: `runBrowser`), or why none, off the main thread. A check hands
    /// in its own.
    var finder: @Sendable (_ setting: String) -> Result<RunBrowser.Spec, RunBrowser.Problem> = { RunBrowsers.find(setting: $0) }
    /// The clipboard a page's own copy lands on, and (a check only) its word on whether the person typed or
    /// clicked: a check gives both, so it never reads or changes the person's clipboard.
    var clipboard: NSPasteboard = .general
    var copyHands: (@Sendable () -> Bool)?
    /// The watches under way.
    private(set) var copyWatches = 0
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
    nonisolated static func find(setting: String) -> Result<RunBrowser.Spec, RunBrowser.Problem> {
        var found: [String: URL] = [:]
        for known in RunBrowserRules.browsers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundle), signed(url, by: known) else { continue }
            found[known.bundle] = url
        }
        let none = RunBrowser.Problem(RunBrowserRules.none)
        guard !found.isEmpty else { return .failure(none) }
        let running = Set(NSWorkspace.shared.personsApplications.compactMap(\.bundleIdentifier))
        // The browser the person's links open in, by macOS's own word, asked now: a run never gets that one.
        let standard = URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
        switch RunBrowserRules.choose(installed: Array(found.keys), running: running, standard: standard, setting: setting) {
        case .none: return .failure(none)
        case .theirs(let known, let named): return .failure(.init(RunBrowserRules.theirs(known.name, named: named)))
        case .browser(let pick):
            guard let url = found[pick.bundle], let executable = Bundle(url: url)?.executableURL?.path else { return .failure(none) }
            let bundle = pick.bundle
            return .success(RunBrowser.Spec(bundle: bundle, name: pick.name, executable: executable, verify: { VaultReader.isBrowser(pid: $0, bundle: bundle) }))
        }
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
                case .ended, .circular, .turnEnded: done(.failure(.init(why.words)))
                }
            case .success(let display): self.start(group, caller: caller, display: display, done)
            }
        }
    }

    private func start(_ group: String, caller: String, display: RunDisplays.Display, _ done: @escaping (Result<RunBrowser, RunBrowser.Problem>) -> Void) {
        if let browser = browsers[group], browser.alive { return done(.success(browser)) }
        if let now = starting[group] {
            // One launch per run: another asker of the same run waits for the same one.
            if now.display === display { starting[group]?.waiters.append(done); return }
            // A launch for a display that's gone (its run ended, this is a new one): ended, never taken over.
            cancelStart(group)
        }
        let launch = RunBrowser.Launch()
        starting[group] = Starting(launch: launch, display: display, waiters: [done])
        let finder = self.finder, setting = app.config.string("runBrowser")
        let frame = RunBrowser.windowFrame(on: display.frame)
        let profile = (Self.root as NSString).appendingPathComponent(RunBrowserRules.folderName(group: group, nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()))
        watch()
        // Each launch on a thread of its own: one browser slow to start never holds another run's back.
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<RunBrowser, RunBrowser.Problem> = .failure(.init(RunDisplays.Failure.ended.words))
            if !launch.cancelled {
                switch finder(setting) {
                case .success(let spec): result = RunBrowser.launch(spec: spec, group: group, profile: profile, frame: frame, launch: launch)
                case .failure(let why): result = .failure(why)
                }
            }
            let finished = result
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.started(finished, launch: launch, group: group, caller: caller) }
            }
        }
    }

    /// A launch came back. Only the launch the group is still waiting for counts, and only for the very display it
    /// was started for: one that was cancelled (its waiters heard then), or whose run ended and began again
    /// meanwhile, is thrown away, its browser ended and its profile removed.
    private func started(_ result: Result<RunBrowser, RunBrowser.Problem>, launch: RunBrowser.Launch, group: String, caller: String) {
        guard let now = starting[group], now.launch === launch else {
            if case .success(let browser) = result { browser.end() }
            return
        }
        starting[group] = nil
        var answer = result
        if case .success(let browser) = result {
            if app.displays.displays[group] === now.display, now.display.ready, app.config.bool("runDisplays"), !launch.cancelled {
                browsers[group] = browser
                adopt(browser, group: group, caller: caller)
            } else {
                browser.end()
                answer = .failure(.init(RunDisplays.Failure.ended.words))
            }
        }
        for waiter in now.waiters { waiter(answer) }
        if browsers.isEmpty, starting.isEmpty { unwatch() }
    }

    /// Ends a launch under way for a group: nothing more of it is started, a browser it already started is ended (its
    /// profile with it), and whoever waited hears the run's display went.
    private func cancelStart(_ group: String) {
        guard let now = starting.removeValue(forKey: group) else { return }
        now.launch.cancel()
        for waiter in now.waiters { waiter(.failure(.init(RunDisplays.Failure.ended.words))) }
    }

    /// A browser that just started: a Buy said in it ends when its page moves on, and its window is the run's own
    /// (Show me brings it to the person's screen with the rest).
    private func adopt(_ browser: RunBrowser, group: String, caller: String) {
        let window = browser.window
        browser.onLeft = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.app.assist.computer.seen([], window: window) } }
        }
        browser.clipboard = clipboard
        browser.onPress = { [weak self, weak browser] mark in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchCopy(mark, browser) } }
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

    /// A press went to a page of a run's browser, and a page may copy on a press. So the clipboard is watched for a
    /// while after, as after one of petal_act's Copy buttons (Acting.CopyWatch, by the same rule): a copy that came
    /// with the press and holds a saved secret, or anything Petal typed for the vault, is cleared, never one the
    /// person may have made (they typed or clicked meanwhile) and nothing is ever put back. The reply doesn't wait
    /// for it: the run's next answer says so, and What Petal AI did.
    private func watchCopy(_ mark: Acting.CopyMark, _ browser: RunBrowser?) {
        copyWatches += 1
        Acting.CopyWatch.start(mark, wait: RunBrowserRules.copyWatch, pasteboard: clipboard, hands: copyHands) { [weak self, weak browser] cleared in
            self?.copyWatches -= 1
            guard cleared != nil else { return }
            browser?.say(RunBrowserRules.copyCleared)
            self?.app.assist.did("Cleared the clipboard after a page copied one of your secrets (a browser of its own)")
        }
    }

    // MARK: Ending

    private func ended(_ group: String) {
        guard let browser = browsers.removeValue(forKey: group) else { return }
        app.assist.computer.seen([], window: browser.window)
        browser.end()
        if browsers.isEmpty, starting.isEmpty { unwatch() }
    }

    /// A run's display is going (its run ended: done, failed, stopped, paused, its note thrown away; or hidden
    /// displays were turned off): its browser ends first, so its window is never left to land on the person's screen,
    /// and so does one still being started for it.
    func displayGoing(_ group: String) {
        cancelStart(group)
        ended(group)
    }

    /// Petal is quitting: every run's browser ends now, started or still starting, and its profile goes before Petal does.
    func quit() {
        for group in Array(starting.keys) { cancelStart(group) }
        for (group, browser) in browsers {
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
    var startingCount: Int { starting.count }
}
