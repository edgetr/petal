import Foundation

// Checks IPC.swift's hanging up: a client that goes before its request's handler gets its turn on the main thread
// never reaches the handler (so an already allowed Trash or quit can't run for nobody), and a handler already running
// sees `hungUp` at once, before the main thread has heard of it. Also that a client that waits gets its answer. It
// serves a throwaway socket in the temporary folder (this Config stands in for Petal's), never Petal's own, and talks
// to no running Petal. Run with macos/checks/run.sh.

/// Stands in for Petal's Config: IPC.path is the socket in this folder.
enum Config {
    static let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-ipc-check-\(getpid())")
}

@main
struct IPCCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if !condition { failures += 1; print("FAIL: \(what) \(detail())") }
    }

    /// What the stand-in for Assist saw and did.
    @MainActor static var started: [String] = []
    @MainActor static var acted: [String] = []
    @MainActor static var cleaned: [String] = []
    @MainActor static var requests: [String: IPC.Pending] = [:]

    @MainActor static func main() {
        let path = IPC.path
        guard path.hasPrefix(NSTemporaryDirectory()), !path.contains("/.config/petal/") else {
            print("FAIL: not a throwaway socket: \(path)"); exit(1)
        }
        try? FileManager.default.createDirectory(at: Config.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: Config.folder) }

        let ipc = IPC()
        // As App.swift's "assist": what it does for its request is the Trash or a quit, unless its client has gone.
        ipc.onFrom("assist") { args, _, request, reply in
            let id = args.first ?? ""
            started.append(id)
            requests[id] = request
            request.onHangUp { cleaned.append(id) }
            guard !request.hungUp else { return }
            if args.dropFirst().first == "later" { return }   // answers later (a card up), as a tool asking first
            acted.append(id)
            reply("ok")
        }
        ipc.start()
        defer { ipc.stop() }
        guard FileManager.default.fileExists(atPath: path) else { print("FAIL: the throwaway socket isn't there"); exit(1) }

        // 1. The client sends its line and goes while the main thread is busy: by the time the handler's turn comes,
        //    its socket's thread has seen it go. The handler never runs, so nothing is done.
        guard let gone = connectTo(path) else { print("FAIL: can't connect"); exit(1) }
        send(gone, #"["assist","gone"]"#)
        close(gone)
        Thread.sleep(forTimeInterval: 1.0)   // the main thread busy: the handler queued, the client already gone
        spin(0.5)
        expect(!started.contains("gone"), "a request whose client went before its turn never reaches its handler", "\(started)")
        expect(!acted.contains("gone"), "nothing is done for a client that went before its turn")

        // 2. A handler already running (answering later) whose client goes while the main thread is busy: the next
        //    check it makes on the main thread, before the main thread hears of it, sees it hung up; what it left
        //    waiting is undone after, once.
        guard let waiting = connectTo(path) else { print("FAIL: can't connect"); exit(1) }
        send(waiting, #"["assist","waiting","later"]"#)
        spin(0.5)
        expect(started.contains("waiting") && requests["waiting"]?.hungUp == false, "a request whose client is there runs, not hung up")
        close(waiting)
        Thread.sleep(forTimeInterval: 1.0)   // the socket's thread sees it go; the main thread hasn't run since
        expect(requests["waiting"]?.hungUp == true, "a running request is hung up as soon as its client goes, before the main thread hears")
        expect(!cleaned.contains("waiting"), "what it left waiting is undone on the main thread, not on the socket's")
        spin(0.5)
        expect(cleaned == ["waiting"], "what it left waiting is undone once", "\(cleaned)")
        expect(!acted.contains("waiting"), "nothing is done for it")

        // 3. A client that waits gets its answer.
        guard let staying = connectTo(path) else { print("FAIL: can't connect"); exit(1) }
        send(staying, #"["assist","staying"]"#)
        let answer = Answer()
        Thread.detachNewThread {
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = read(staying, &bytes, bytes.count)
            answer.set(count > 0 ? String(decoding: bytes[0..<count], as: UTF8.self) : "")
        }
        let until = Date().addingTimeInterval(3)
        while answer.get() == nil, Date() < until { spin(0.05) }
        close(staying)
        expect(answer.get() == "ok\n", "a client that waits hears its answer", "\(answer.get() ?? "nothing")")
        expect(acted.contains("staying") && requests["staying"]?.hungUp == false, "its request was done, not hung up")

        if failures > 0 { print("\(failures) IPC check(s) failed"); exit(1) }
        print("ipc: all checks passed")
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func connectTo(_ path: String) -> Int32? {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in path.utf8.enumerated() { buffer[i] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(client); return nil }
        return client
    }

    static func send(_ client: Int32, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, bytes.count) }
    }
}

private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    func set(_ value: String) { lock.withLock { text = value } }
    func get() -> String? { lock.withLock { text } }
}
