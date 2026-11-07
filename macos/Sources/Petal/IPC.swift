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
    /// socket itself (AgentCallers), never from what the caller says.
    typealias From = @MainActor ([String], AgentAccess.Caller, @escaping @MainActor (String) -> Void) -> Void
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
                    handler(Array(words.dropFirst()), caller, finish)
                } else if let handler = self.later[name] {
                    handler(Array(words.dropFirst()), finish)
                } else if let handler = self.handlers[name] {
                    finish(handler(Array(words.dropFirst())))
                } else {
                    finish("unknown function; try: " + (Array(self.handlers.keys) + Array(self.later.keys) + Array(self.from.keys)).sorted().joined(separator: ", "))
                }
            }
        }
        done.wait()
        let reply = answer.text
        let out = Array((reply + "\n").utf8)
        _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
        close(client)
    }
}

/// One reply, handed from the main thread to the socket's.
private final class Answer: @unchecked Sendable {
    var given = false
    var text = ""
}
