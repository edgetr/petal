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
        // A card waits up to two minutes for the person: this waits a little longer.
        let reply = MCP.petal(["agentKeys", String(decoding: json, as: UTF8.self)], timeout: 150)
        guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
            CLI.fail(reply.hasPrefix("unknown function") ? "This Petal is too old for petal run: update it (petal update)." : reply.isEmpty ? "Petal didn't answer." : reply)
        }
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
        // The signals this process passes on are back to their defaults in the command, and none is blocked.
        let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in forwarded + [SIGPIPE] { sigaddset(&defaults, signal) }
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

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
        // Ctrl-C and the like reach the command (and only it decides when to stop); a signal sent to this process
        // alone (an agent stopping it) is passed on.
        var sources: [DispatchSourceSignal] = []
        let child = pid
        for number in forwarded {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { kill(child, number) }
            source.resume()
            sources.append(source)
        }
        let secrets = keys.map { (secret: $0.secret, label: $0.title) }
        let streams = DispatchGroup()
        for (from, to) in [(out.read, Int32(1)), (err.read, Int32(2))] {
            streams.enter()
            Thread.detachNewThread {
                relay(from: from, to: to, secrets: secrets)
                streams.leave()
            }
        }
        if let input {
            // The keys, one a line, then the end of the input. A command that doesn't read it isn't held up.
            Thread.detachNewThread {
                let text = Array(keys.map { $0.secret + "\n" }.joined().utf8)
                writeAll(input.write, text)
                close(input.write)
            }
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        // What it printed last, still on its way; something it left running in the background with the same output
        // isn't waited for.
        _ = streams.wait(timeout: .now() + 2)
        sources.forEach { $0.cancel() }
        let signalled = status & 0x7f
        if signalled == 0 { return (status >> 8) & 0xff }
        return 128 + signalled
    }

    /// Passes what the command prints on `from` to this process's `to`, with the keys taken out.
    private static func relay(from: Int32, to: Int32, secrets: [(secret: String, label: String)]) {
        var redactor = AgentAccess.Redactor(secrets)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(from, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            writeAll(to, redactor.feed(Array(buffer[..<count])))
        }
        writeAll(to, redactor.finish())
        close(from)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return }
            offset += written
        }
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
