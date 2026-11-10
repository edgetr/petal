import Foundation

/// How scripts and the AI's tools reach the running Petal: a Unix socket at ~/.config/petal/petal.sock. A client writes one line, the function and its arguments as a JSON array
/// (["dock", "macos"]), and reads one line back. Only the person's own account can open it.
///
///     printf '["version"]\n' | nc -U ~/.config/petal/petal.sock
@MainActor
final class IPC {
    nonisolated static let path = Config.folder.appending(path: "petal.sock").path
    typealias Handler = @MainActor ([String]) -> String
    /// A function that needs to know who's asking (the vault, for agents outside Petal): Petal works it out from the
    /// socket itself (AgentCallers), never from what the caller says. It's handed its request, to hear when the
    /// client goes and to say when the person has a card up for it (`Pending`).
    typealias From = @MainActor ([String], AgentAccess.Caller, Pending, @escaping @MainActor (String) -> Void) -> Void

    /// An identified request still waiting for its answer, as its handler sees it. `hungUp`: its client went (closed,
    /// or was killed) before the answer. The socket's thread sets it the moment it sees the client go, so it's true at
    /// once on every thread, even for a handler queued on the main thread before the client went and not yet run: that
    /// one never starts, and every check a running one makes (`Assist.handle`'s `live`) sees it before its next step.
    /// What `onHangUp` holds runs after, once, on the main thread, so nothing it asked for goes on with nobody to hear
    /// the answer. `waiting`, set by the handler: the person has a card up for this request now. While they do, the
    /// client is sent a space every 10 seconds ahead of the answer's line, so a request that asks more than once (an
    /// agent's card, then the app's) never runs out of time while they read.
    @MainActor final class Pending {
        nonisolated private let gone = Flag()
        nonisolated var hungUp: Bool { gone.isSet }
        var waiting: (() -> Bool)?
        private var cleanup: [() -> Void] = []
        private var cleanedUp = false

        nonisolated init() {}

        /// The socket's thread saw the client go: from now on the request is hung up, before anything on the main
        /// thread hears of it.
        nonisolated func cancel() { gone.set() }

        func onHangUp(_ body: @escaping () -> Void) {
            if cleanedUp { body() } else { cleanup.append(body) }
        }

        /// What the request left waiting is undone, on the main thread, once.
        func hangUp() {
            gone.set()
            guard !cleanedUp else { return }
            cleanedUp = true
            let all = cleanup
            cleanup = []
            all.forEach { $0() }
        }
    }
    private var handlers: [String: Handler] = [:]
    private var from: [String: From] = [:]
    private var fd: Int32 = -1
    /// The functions registered with `onFrom`: the socket's thread identifies their callers before they run.
    nonisolated static let identified: Set<String> = ["assist", "agentKeys"]

    func on(_ name: String, _ handler: @escaping Handler) { handlers[name] = handler }
    func onFrom(_ name: String, _ handler: @escaping From) {
        precondition(Self.identified.contains(name))
        from[name] = handler
    }

    /// Another Petal answers on the socket already: this one mustn't take it from it.
    nonisolated static func answering() -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    func start() {
        guard !Self.answering() else { return }
        unlink(Self.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); fd = -1; return }
        chmod(Self.path, 0o600)
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { break }
                // A client that hung up before its answer (a tool waiting on the person) must never kill Petal.
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // Each on its own thread: one waiting for an answer never holds up the rest.
                Thread.detachNewThread { self?.serve(client) }
            }
        }
    }

    func stop() {
        if fd >= 0 { close(fd) }
        unlink(Self.path)
    }

    /// Runs on the socket's thread; the handler itself runs on the main thread, where the dock lives.
    nonisolated private func serve(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.count > 1_000_000 { break }
        }
        let line = String(decoding: data.prefix { $0 != 0x0A }, as: UTF8.self)
        let words: [String]
        if let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any] {
            words = parsed.map { "\($0)" }
        } else {
            words = line.split(separator: " ").map(String.init)
        }
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        // Who's asking, read here (off the main thread) from the socket itself.
        let caller = Self.identified.contains(words.first ?? "") ? AgentCallers.identify(client: client) : nil
        let pending = Pending()
        // Its client watched from here on: one already gone is hung up before its handler is even queued.
        let peer = caller == nil ? nil : Peer(client)
        if peer?.gone() == true { pending.cancel() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let name = words.first ?? ""
                let finish: @MainActor (String) -> Void = { text in
                    guard !answer.given else { return }
                    answer.given = true
                    answer.text = text
                    done.signal()
                }
                if let handler = self.from[name], let caller {
                    // Its client went while it waited its turn here: nothing is done for nobody.
                    guard !pending.hungUp else { return }
                    handler(Array(words.dropFirst()), caller, pending, finish)
                } else if let handler = self.handlers[name] {
                    finish(handler(Array(words.dropFirst())))
                } else {
                    finish("unknown function; try: " + (Array(self.handlers.keys) + Array(self.from.keys)).sorted().joined(separator: ", "))
                }
            }
        }
        if caller == nil {
            done.wait()
        } else if let peer, !Self.wait(done, client: client, peer: peer, pending: pending) {
            close(client)
            return
        }
        let reply = answer.text
        let out = Array((reply + "\n").utf8)
        _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
        close(client)
    }
}

extension IPC {
    /// Waits for an identified request's answer, watching its client: once it has gone (its end closed, not only its
    /// writing half, as `nc` does once it has sent its line), the request is hung up there and then (`cancel`), what
    /// it left waiting is undone on the main thread (`hangUp`), and false says nobody is left to answer. While the
    /// person has a card up for it, the client hears a space every 10 seconds.
    nonisolated fileprivate static func wait(_ done: DispatchSemaphore, client: Int32, peer: Peer, pending: Pending) -> Bool {
        let beat = Beat()
        var asked = DispatchTime.now()
        while true {
            if peer.gone() {
                pending.cancel()
                DispatchQueue.main.async { MainActor.assumeIsolated { pending.hangUp() } }
                return false
            }
            if done.wait(timeout: .now() + 0.25) == .success { return true }
            if beat.take() {
                var space: UInt8 = 0x20
                _ = write(client, &space, 1)
            }
            if DispatchTime.now() >= asked + 10 {
                asked = .now()
                DispatchQueue.main.async { MainActor.assumeIsolated { if pending.waiting?() == true { beat.set() } } }
            }
        }
    }
}

/// Whether a request's client has gone, asked from the socket's thread. A closed peer ends this socket's sending side
/// too: the write filter says so (EV_EOF); a half-close doesn't.
private final class Peer {
    private let queue: Int32
    private let watching: Bool

    init(_ client: Int32) {
        queue = kqueue()
        var watch = kevent(ident: UInt(client), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        watching = queue >= 0 && kevent(queue, &watch, 1, nil, 0, nil) == 0
    }

    deinit { if queue >= 0 { close(queue) } }

    func gone() -> Bool {
        guard watching else { return false }
        var event = kevent()
        var now = timespec(tv_sec: 0, tv_nsec: 0)
        return kevent(queue, nil, 0, &event, 1, &now) > 0 && event.flags & UInt16(EV_EOF) != 0
    }
}

/// Set once, read from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
}

/// The main thread saying a request's client should hear it's still waiting on the person.
private final class Beat: @unchecked Sendable {
    private let lock = NSLock()
    private var due = false
    func set() { lock.withLock { due = true } }
    func take() -> Bool { lock.withLock { defer { due = false }; return due } }
}

/// One reply, handed from the main thread to the socket's.
private final class Answer: @unchecked Sendable {
    var given = false
    var text = ""
}
