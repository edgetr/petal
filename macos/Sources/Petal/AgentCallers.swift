import Foundation
import Security

/// Who's asking on Petal's socket, worked out by Petal itself and never from what the caller says: the process that
/// connected (its audit token, from the socket), whether it's Petal's own code (`petal run`, `Petal --mcp`) by its
/// signature, its folder (the project), and the processes above it, up to an agent signed by its maker (Claude Code,
/// Codex) and the app it runs in (T3 Code, Terminal, Ghostty…). Off the main thread; the pure part is AgentAccess.
enum AgentCallers {
    /// The caller connected on `client`. Runs on the socket's thread.
    nonisolated static func identify(client: Int32, petal: Int32 = getpid()) -> AgentAccess.Caller {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
            return AgentAccess.Caller(agent: .unknown, host: nil, project: "/", program: "", peerIsPetal: false)
        }
        let pid = Int32(bitPattern: token.val.5)
        let peerIsPetal = isPetal(token)
        var chain: [AgentAccess.Process] = []
        var current = pid
        var seen = Set<Int32>()
        while current > 1, chain.count < 24, seen.insert(current).inserted {
            guard let info = bsdInfo(current) else { break }
            var process = AgentAccess.Process(pid: current, path: path(of: current))
            // Who signed it, for everything above what connected that could be an agent (never a system shell).
            if !chain.isEmpty, !process.path.hasPrefix("/bin/"), !process.path.hasPrefix("/usr/"), !process.path.hasPrefix("/System/") {
                (process.team, process.identifier) = signer(current, start: info.start)
            }
            chain.append(process)
            current = info.parent
        }
        let folder = workingFolder(pid).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? "/"
        let project = AgentAccess.project(folder, git: gitMark)
        return AgentAccess.caller(chain: chain, petalPID: petal, peerIsPetal: peerIsPetal, project: project)
    }

    /// Petal's own designated requirement: what connected is this very app (the same signature), checked now.
    nonisolated(unsafe) private static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    nonisolated private static func isPetal(_ token: audit_token_t) -> Bool {
        guard let requirement = ownRequirement else { return false }
        var token = token
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Processes

    private struct Info { let parent: Int32; let start: UInt64 }

    nonisolated private static func bsdInfo(_ pid: Int32) -> Info? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Info(parent: Int32(info.pbi_ppid), start: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }

    nonisolated private static func path(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    nonisolated private static func workingFolder(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    nonisolated static func gitMark(_ folder: String) -> AgentAccess.GitMark? {
        let git = folder == "/" ? "/.git" : folder + "/.git"
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue { return .folder }
        guard let handle = FileHandle(forReadingAtPath: git) else { return nil }
        defer { try? handle.close() }
        return .file(String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var signers: [String: (team: String?, identifier: String?)] = [:]

    /// Who signed a running process (its Team ID, "apple" for Apple's own, and its identifier), when its signature
    /// checks out now; kept for as long as that process lives (by its pid and start).
    nonisolated private static func signer(_ pid: Int32, start: UInt64) -> (String?, String?) {
        let key = "\(pid)/\(start)"
        lock.lock()
        if let known = signers[key] { lock.unlock(); return known }
        lock.unlock()
        var found: (team: String?, identifier: String?) = (nil, nil)
        var code: SecCode?
        if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code,
           SecCodeCheckValidity(code, [], nil) == errSecSuccess {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let info = info as? [String: Any] {
                found.identifier = info[kSecCodeInfoIdentifier as String] as? String
                found.team = info[kSecCodeInfoTeamIdentifier as String] as? String
                if found.team == nil, let id = found.identifier {
                    var requirement: SecRequirement?
                    if SecRequirementCreateWithString("anchor apple and identifier \"\(id)\"" as CFString, [], &requirement) == errSecSuccess,
                       SecCodeCheckValidity(code, [], requirement) == errSecSuccess { found.team = "apple" }
                }
            }
        }
        // Still the same process: a pid taken by another meanwhile keeps nothing.
        guard bsdInfo(pid)?.start == start else { return (nil, nil) }
        lock.lock()
        if signers.count > 500 { signers.removeAll() }
        signers[key] = found
        lock.unlock()
        return found
    }
}
