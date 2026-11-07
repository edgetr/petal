import Foundation

/// `petal run --key "<title or id>" [--env NAME] [--stdin] -- <command…>`: runs a command with API keys from the
/// vault, for an agent testing with a real key without ever seeing it. This process asks the running Petal for the
/// keys over its socket (Petal checks it's Petal's own code, works out which agent and project it's for, and asks the
/// person unless they granted it), starts the command with them in its variables (or on its input), and passes on
/// what the command prints with every key taken out ("[Anthropic key]"), and its exit code. The key is never printed
/// here. It keeps keys out of the agent's transcript and logs; a command written to leak one on purpose still can.
enum AgentRun {
    static func run(_ arguments: [String]) -> Never {
        let request: AgentAccess.Run
        switch AgentAccess.parseRun(arguments) {
        case .success(let parsed): request = parsed
        case .failure(let error): CLI.fail(error.text)
        }
        // A command that can't start never asks the person for a key.
        guard findable(request.command[0]) else { CLI.fail("petal run can't find \(request.command[0]).") }
        let line = AgentAccess.commandLine(request.command)
        let ask: [String: Any] = ["keys": request.keys.map { key -> [String: Any] in
            var entry: [String: Any] = ["ref": key.ref]
            if let variable = key.variable { entry["env"] = variable }
            return entry
        }, "command": line, "stdin": request.stdin]
        guard let json = try? JSONSerialization.data(withJSONObject: ask) else { CLI.fail("Couldn't ask Petal.") }
        // Petal answers within 150 seconds, or keeps saying it's waiting while its card is up for the person. Leaving
        // (an agent stopping this, or giving up) answers its card Don't, so no key is given with nobody to take it.
        var answer: [UInt8]
        switch MCP.petalAnswer(["agentKeys", String(decoding: json, as: UTF8.self)], timeout: 150) {
        case .failed(let text): CLI.fail(text)   // this side's own words: nothing Petal sent
        case .bytes(let bytes): answer = bytes
        }
        // An answer cut short or garbled may still hold a key: it's never shown, only a fixed sentence, and the
        // bytes are zeroed before anything else happens.
        var data = Data(answer)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let unreadable = object == nil ? AgentAccess.unreadable(answer) : nil
        data.resetBytes(in: 0..<data.count)
        MCP.wipe(&answer)
        guard let object else { CLI.fail(unreadable ?? AgentAccess.unreadableText) }
        if let error = object["error"] as? String { CLI.fail(error) }
        let keys = (object["keys"] as? [[String: Any]] ?? []).compactMap { entry -> (title: String, secret: String, variable: String?)? in
            guard let title = entry["title"] as? String, let secret = entry["secret"] as? String, !secret.isEmpty else { return nil }
            return (title, secret, entry["env"] as? String)
        }
        guard keys.count == request.keys.count else { CLI.fail("Petal didn't give every key asked for.") }
        // An older Petal may still hand over a key too short to find in all its forms: it never reaches the command.
        if let short = keys.first(where: { AgentAccess.Redactor.tooShort($0.secret) }) { CLI.fail("“\(short.title)”: " + AgentAccess.Redactor.tooShortText) }
        exit(spawn(request.command, keys: keys, stdin: request.stdin))
    }

    /// Runs the command and waits for it: its exit code, or 128 + the signal that ended it.
    private static func spawn(_ command: [String], keys: [(title: String, secret: String, variable: String?)], stdin: Bool) -> Int32 {
        // A command that stops reading (or an agent that stops listening) ends a write, never this process.
        signal(SIGPIPE, SIG_IGN)
        var environment = ProcessInfo.processInfo.environment
        for key in keys { if let variable = key.variable { environment[variable] = key.secret } }
        let out = pipe(), err = pipe()
        let input = stdin ? pipe() : nil
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, out.write, 1)
        posix_spawn_file_actions_adddup2(&actions, err.write, 2)
        if let input { posix_spawn_file_actions_adddup2(&actions, input.read, 0) }
        for fd in [out.read, out.write, err.read, err.write] + (input.map { [$0.read, $0.write] } ?? []) {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        // The signals this process takes over are back to their defaults in the command, and none is blocked.
        let handled = AgentAccess.handledSignals
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in handled + [SIGPIPE] { sigaddset(&defaults, signal) }
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        // A SIGTERM or SIGHUP sent to this process alone (an agent stopping it) is passed on, even one that comes
        // while the command is starting.
        let forward = Forward()
        var sources: [DispatchSourceSignal] = []
        for number in handled where AgentAccess.onSignal(number) == .forward {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { forward.send(number) }
            source.resume()
            sources.append(source)
        }

        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let started = posix_spawnp(&pid, command[0], &actions, &attributes, argv, envp)
        for fd in [out.write, err.write] + (input.map { [$0.read] } ?? []) { close(fd) }
        guard started == 0 else {
            close(out.read); close(err.read)
            if let input { close(input.write) }
            CLI.fail("petal run couldn't start \(command[0]): \(String(cString: strerror(started))).")
        }
        let child = pid
        forward.started(child)
        // Ctrl-C and Ctrl-\ reach the command from the terminal (it's in this process group), and only it decides
        // when to stop: from now on this process ignores them and ends when it does, with its status. (Until now they
        // end this process, and the command with it.)
        for number in handled where AgentAccess.onSignal(number) == .ignore { signal(number, SIG_IGN) }
        let secrets = keys.map { (secret: $0.secret, label: $0.title) }
        let streams = DispatchGroup()
        let stop = Stop()
        for (from, to) in [(out.read, Int32(1)), (err.read, Int32(2))] {
            streams.enter()
            Thread.detachNewThread {
                relay(from: from, to: to, secrets: secrets, stop: stop)
                streams.leave()
            }
        }
        if let input {
            // The keys, one a line, then the end of the input. A command that doesn't read it isn't held up.
            Thread.detachNewThread {
                let text = Array(keys.map { $0.secret + "\n" }.joined().utf8)
                _ = writeAll(input.write, text)
                close(input.write)
            }
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        // What it printed last, still on its way; something it left running in the background with the same output
        // isn't waited for: 2 seconds on, each stream stops reading, takes only what's in its pipe right then, and
        // ends. Everything read is passed on however long the agent takes to read it: an agent that paused reading
        // still gets all of it, and only one that closed its end loses the rest.
        stop.at(.now() + 2)
        streams.wait()
        sources.forEach { $0.cancel() }
        let signalled = status & 0x7f
        if signalled == 0 { return (status >> 8) & 0xff }
        return 128 + signalled
    }

    /// Passes a signal on to the command, holding one that came before it started until it has.
    private final class Forward: @unchecked Sendable {
        private let lock = NSLock()
        private var child: pid_t = 0
        private var waiting: [Int32] = []

        func send(_ number: Int32) {
            lock.withLock { if child > 0 { _ = kill(child, number) } else { waiting.append(number) } }
        }

        func started(_ pid: pid_t) {
            lock.withLock {
                child = pid
                for number in waiting { _ = kill(pid, number) }
                waiting = []
            }
        }
    }

    /// When the streams stop waiting for more: set once the command has ended.
    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var deadline: DispatchTime?

        func at(_ time: DispatchTime) { lock.withLock { deadline = time } }
        var passed: Bool { lock.withLock { deadline.map { DispatchTime.now() >= $0 } ?? false } }
    }

    /// Passes what the command prints on `from` to this process's `to`, with the keys taken out (AgentAccess.relay):
    /// until the end of its output, or `stop` (something the command left running keeps the output open), and then
    /// only what's in the pipe right then; all of it written on, however long that takes.
    private static func relay(from: Int32, to: Int32, secrets: [(secret: String, label: String)], stop: Stop) {
        var redactor = AgentAccess.Redactor(secrets)
        var buffer = [UInt8](repeating: 0, count: 65536)
        AgentAccess.relay(&redactor, chunk: buffer.count, read: { most in
            var ready = pollfd(fd: from, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 100)
            if polled < 0 { return errno == EINTR ? .nothingYet : .ended }
            if polled == 0 { return .nothingYet }
            let count = read(from, &buffer, min(most, buffer.count))
            if count < 0, errno == EINTR || errno == EAGAIN { return .nothingYet }
            if count <= 0 { return .ended }
            return .bytes(Array(buffer[..<count]))
        }, waiting: {
            var count: Int32 = 0
            return ioctl(from, fionread, &count) == 0 ? Int(count) : 0
        }, write: { writeAll(to, $0) }, stopped: { stop.passed })
        close(from)
    }

    /// <sys/filio.h>'s FIONREAD, _IOR('f', 127, int), which Swift doesn't import: how many bytes a pipe holds.
    private static let fionread: UInt = 0x4000_0000 | (UInt(MemoryLayout<Int32>.size) << 16) | (UInt(UInt8(ascii: "f")) << 8) | 127

    /// Writes all of `bytes`, waiting as long as the reader takes (an end that doesn't block says EAGAIN when the
    /// pipe is full: it waits until it takes more); false once its end is closed (or another error).
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        AgentAccess.writeAll(bytes, write: { part in
            let written = part.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            return (written, written < 0 ? errno : 0)
        }, writable: {
            while true {
                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&ready, 1, -1)
                if polled < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
                // A closed reader shows as POLLHUP or POLLERR: the next write says EPIPE.
                return ready.revents & Int16(POLLNVAL) == 0
            }
        })
    }

    /// The command is a program that can run: a path to one, or a name found in PATH.
    private static func findable(_ name: String) -> Bool {
        if name.contains("/") { return access(name, X_OK) == 0 }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { access("\($0)/\(name)", X_OK) == 0 }
    }

    private static func pipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { CLI.fail("petal run couldn't make a pipe.") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }
}
