import Foundation

/// How scripts and Claude reach the running Petal on macOS, as `omarchy-shell petal <fn>` does on Omarchy: a Unix
/// socket at ~/.config/petal/petal.sock. A client writes one line, the function and its arguments as a JSON array
/// (["mode", "social"]), and reads one line back. Only the person's own account can open it.
///
///     printf '["current"]\n' | nc -U ~/.config/petal/petal.sock
@MainActor
final class IPC {
    static let path = Config.folder.appending(path: "petal.sock").path
    typealias Handler = @MainActor ([String]) -> String
    private var handlers: [String: Handler] = [:]
    private var fd: Int32 = -1

    func on(_ name: String, _ handler: @escaping Handler) { handlers[name] = handler }

    func start() {
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
                self?.serve(client)
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
        let reply = DispatchQueue.main.sync {
            MainActor.assumeIsolated { () -> String in
                guard let name = words.first, let handler = self.handlers[name] else {
                    return "unknown function; try: " + self.handlers.keys.sorted().joined(separator: ", ")
                }
                return handler(Array(words.dropFirst()))
            }
        }
        let out = Array((reply + "\n").utf8)
        _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
        close(client)
    }
}
