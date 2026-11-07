import Foundation

/// How scripts and Claude reach the running Petal on macOS, as `omarchy-shell petal <fn>` does on Omarchy: a Unix
/// socket at ~/.config/petal/petal.sock. A client writes one line, the function and its arguments as a JSON array
/// (["mode", "social"]), and reads one line back. Only the person's own account can open it.
///
///     printf '["current"]\n' | nc -U ~/.config/petal/petal.sock
@MainActor
final class IPC {
    nonisolated static let path = Config.folder.appending(path: "petal.sock").path
    typealias Handler = @MainActor ([String]) -> String
    /// A function that answers later (the AI's tools waiting for the person to allow something): it calls `reply`
    /// once, on the main thread.
    typealias Later = @MainActor ([String], @escaping @MainActor (String) -> Void) -> Void
    /// A function that needs to know who's asking (the vault, for agents outside Petal): Petal works it out from the
    /// socket itself (AgentCallers), never from what the caller says. It's handed its request, to hear when the
    /// client goes and to say when the person has a card up for it (`Pending`).
    typealias From = @MainActor ([String], AgentAccess.Caller, Pending, @escaping @MainActor (String) -> Void) -> Void

    /// An identified request still waiting for its answer, as its handler sees it. `hungUp`: its client went (closed,
    /// or was killed) before the answer; what `onHangUp` holds runs then, once, on the main thread, so nothing it
    /// asked for goes on with nobody to hear the answer. `waiting`, set by the handler: the person has a card up for
    /// this request now. While they do, the client is sent a space every 10 seconds ahead of the answer's line, so a
    /// request that asks more than once (an agent's card, then the app's) never runs out of time while they read.
    @MainActor final class Pending {
        private(set) var hungUp = false
        var waiting: (() -> Bool)?
        private var cleanup: [() -> Void] = []

        nonisolated init() {}

        func onHangUp(_ body: @escaping () -> Void) {
            if hungUp { body() } else { cleanup.append(body) }
        }

        func hangUp() {
            guard !hungUp else { return }
            hungUp = true
            let all = cleanup
            cleanup = []
            all.forEach { $0() }
        }
    }
    private var handlers: [String: Handler] = [:]
    private var later: [String: Later] = [:]
    private var from: [String: From] = [:]
    private var fd: Int32 = -1
    /// The functions registered with `onFrom`: the socket's thread identifies their callers before they run.
    nonisolated static let identified: Set<String> = ["assist", "agentKeys"]

    func on(_ name: String, _ handler: @escaping Handler) { handlers[name] = handler }
    func onLater(_ name: String, _ handler: @escaping Later) { later[name] = handler }
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
                    handler(Array(words.dropFirst()), caller, pending, finish)
                } else if let handler = self.later[name] {
                    handler(Array(words.dropFirst()), finish)
                } else if let handler = self.handlers[name] {
                    finish(handler(Array(words.dropFirst())))
                } else {
                    finish("unknown function; try: " + (Array(self.handlers.keys) + Array(self.later.keys) + Array(self.from.keys)).sorted().joined(separator: ", "))
                }
            }
        }
        if caller == nil {
            done.wait()
        } else if !Self.wait(done, client: client, pending: pending) {
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
    /// writing half, as `nc` does once it has sent its line), the request hears it (`hangUp`) and false says nobody
    /// is left to answer. While the person has a card up for it, the client hears a space every 10 seconds.
    nonisolated fileprivate static func wait(_ done: DispatchSemaphore, client: Int32, pending: Pending) -> Bool {
        // A closed peer ends this socket's sending side too: the write filter says so (EV_EOF), a half-close doesn't.
        let queue = kqueue()
        defer { if queue >= 0 { close(queue) } }
        var watch = kevent(ident: UInt(client), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        let watching = queue >= 0 && kevent(queue, &watch, 1, nil, 0, nil) == 0
        let beat = Beat()
        var asked = DispatchTime.now()
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if watching {
                var event = kevent()
                var now = timespec(tv_sec: 0, tv_nsec: 0)
                if kevent(queue, nil, 0, &event, 1, &now) > 0, event.flags & UInt16(EV_EOF) != 0 {
                    DispatchQueue.main.async { MainActor.assumeIsolated { pending.hangUp() } }
                    return false
                }
            }
            if beat.take() {
                var space: UInt8 = 0x20
                _ = write(client, &space, 1)
            }
            if DispatchTime.now() >= asked + 10 {
                asked = .now()
                DispatchQueue.main.async { MainActor.assumeIsolated { if pending.waiting?() == true { beat.set() } } }
            }
        }
        return true
    }
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
