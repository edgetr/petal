import AppKit
import CryptoKit

/// The person's own changes to Petal's code, kept through every update. The git work is petal-personal's (a script
/// inside Petal.app at Resources/personal/petal-personal; in the repository, macos/Resources/personal/): it keeps
/// Petal's source in ~/Library/Application Support/Petal/source, where branch `upstream` holds released source and
/// `mine` the person's changes on top. This file gets Apple's command line tools (git, Swift and python3; macOS's
/// own installer asks), builds the changed Petal with the source's macos/build.sh, signs it with a certificate made
/// once for this Mac (so macOS keeps Petal's permissions from one personal build to the next), and installs it over
/// this Petal.
///
/// Updates (Updater.check): while changes exist, a new release's source is combined with them and built, instead of
/// the release's own Petal.app being installed. That Petal.app is still downloaded and checked first, as an update
/// that's installed is (Updater.source): the source is the commit it says it was built from. If it can't be done,
/// this Petal keeps running and the person is told, with an offer to report it.
@MainActor
enum Personal {
    /// PETAL_PERSONAL_HOME moves all of it elsewhere, and keeps a running Petal from being restarted (for testing).
    nonisolated static let testing = ProcessInfo.processInfo.environment["PETAL_PERSONAL_HOME"]
    nonisolated static let folder = testing.map { URL(fileURLWithPath: $0) }
        ?? Config.supportFolder
    nonisolated static var source: URL { folder.appending(path: "source") }
    nonisolated static var built: URL { source.appending(path: ".git/petal-built/Petal.app") }
    nonisolated static var signing: URL { folder.appending(path: "signing") }

    /// What the check builds in the tree it's given, and what's kept of it for installing.
    nonisolated static let buildCheck = "PETAL_SIGN_IDENTITY=- PETAL_ARCHS=$(/usr/bin/uname -m) /bin/bash macos/build.sh"
    nonisolated static let buildOutput = "macos/build/Petal.app"

    nonisolated static var state: [String: Any] {
        (try? Data(contentsOf: source.appending(path: ".git/petal-personal.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    nonisolated static var exists: Bool { !state.isEmpty }
    nonisolated static var inUse: Bool { state["in_use"] as? Bool == true }

    /// Where an agent changes Petal's Swift (petal_get_state's `files.source`), once the source is set up.
    nonisolated static var sourceForAgents: String? {
        FileManager.default.fileExists(atPath: source.appending(path: "macos/Package.swift").path) ? source.appending(path: "macos").path : nil
    }

    /// For agents, in petal_get_state.
    nonisolated static let how = "To change Petal's code so it survives updates: `petal personal init` (once), edit the files in source, then "
        + "`petal personal save \"<what changed>\"`, which builds it and restarts Petal into it. `petal personal help` lists the rest."

    nonisolated static var isDevelopmentBuild: Bool { Bundle.main.bundlePath.contains("/macos/build/") }
    nonisolated static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    // MARK: Apple's command line tools

    /// git, Swift and python3, from the command line tools or Xcode. Asking for them any other way (/usr/bin/git)
    /// would pop macOS's installer when they're missing.
    nonisolated static var developerTools: String? {
        let result = run("/usr/bin/xcode-select", ["-p"])
        let folder = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let has = { (path: String) in FileManager.default.isExecutableFile(atPath: "\(folder)/\(path)") }
        // The command line tools have all three in usr/bin; Xcode keeps Swift in its toolchain.
        guard result.status == 0, !folder.isEmpty, has("usr/bin/git"), has("usr/bin/python3"),
              has("usr/bin/swift") || has("Toolchains/XcodeDefault.xctoolchain/usr/bin/swift") else { return nil }
        return folder
    }

    /// macOS's own "install the command line tools?" window; nobody types anything.
    nonisolated static func installDeveloperTools() {
        _ = run("/usr/bin/xcode-select", ["--install"])
    }

    // MARK: The shared core

    /// The environment petal-personal runs in: the tools, this Petal's version, and the AI the person chose for
    /// the chat, which combines updates with their changes when both touch the same code.
    nonisolated static func environment(tools: String, aiPath: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["PATH"] = ["\(tools)/usr/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        environment["PETAL_PERSONAL_SOURCE"] = source.path
        environment["PETAL_INSTALLED_VERSION"] = version
        environment["PETAL_SOURCE_COMMIT"] = Bundle.main.object(forInfoDictionaryKey: "PetalSourceCommit") as? String ?? ""
        let settings = MCP.read(MCP.settingsFile) ?? [:]
        let chosen = (settings["aiProviders"] as? [String] ?? Settings.defaults["aiProviders"] as? [String] ?? ["claude"]).compactMap(Provider.init(rawValue:))
        let provider = Provider(rawValue: settings["chatProvider"] as? String ?? "").flatMap { chosen.contains($0) ? $0 : nil } ?? chosen.first
        if let provider {
            environment["PETAL_AI"] = provider.rawValue
            if let path = aiPath ?? PetalApp.find(provider, setting: settings[provider.pathSetting] as? String ?? "") {
                environment["PETAL_AI_PATH"] = path
            }
            if let model = settings[provider.modelSetting] as? String, !model.isEmpty { environment["PETAL_AI_MODEL"] = model }
            if let effort = settings[provider.effortSetting] as? String, !effort.isEmpty { environment["PETAL_AI_EFFORT"] = effort }
            // On an API key, the merge runs on it too; chosen with no key saved, no AI merges (never the subscription).
            let api = settings[provider.authSetting] as? String == "api"
            if api && !APIKeys.hasKey(provider) { environment["PETAL_AI_PATH"] = nil; environment["PETAL_AI"] = "none" }
            environment = APIKeys.environment(environment, for: provider, api: api)
        }
        return environment
    }

    /// Runs petal-personal. With `echo`, its output goes straight to the terminal (`petal personal …`).
    nonisolated static func core(_ arguments: [String], tools: String, aiPath: String? = nil, echo: Bool = false) -> (status: Int32, output: String) {
        guard let script = Bundle.main.path(forResource: "petal-personal", ofType: nil, inDirectory: "personal") else {
            return (1, "This Petal.app is missing its petal-personal script; reinstall Petal.")
        }
        return run("\(tools)/usr/bin/python3", ["-I", script] + arguments, environment: environment(tools: tools, aiPath: aiPath), echo: echo)
    }

    /// The JSON line petal-personal ends with when asked for --json.
    nonisolated static func result(_ output: String) -> [String: Any] {
        output.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    }

    // MARK: Signing and installing

    struct Failure: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Signs with Petal's personal identity, made once: a self-made certificate, "Petal (Personal)", in a keychain
    /// of Petal's own, so signing never asks for the person's login password (its own password is kept beside it,
    /// in a file only the person's account can read). macOS ties Petal's permissions (Accessibility, Screen
    /// Recording) to this certificate, so they carry from one personal build to the next. The keychain is unlocked
    /// for `body` only (PersonalSigning.unlocked): locked again on every way out, and by itself after two minutes
    /// without use or when the Mac sleeps, so the key isn't left ready to sign between builds.
    nonisolated static func withIdentity<T>(_ body: (_ keychain: String, _ hash: String) throws -> T) throws -> T {
        let keychain = signing.appending(path: "petal-personal.keychain-db").path
        let passwordFile = signing.appending(path: "password")
        let fm = FileManager.default
        if !fm.fileExists(atPath: keychain) {
            try? fm.removeItem(at: signing)
            try fm.createDirectory(at: signing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let password = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            try Data(password.utf8).write(to: passwordFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
            let work = fm.temporaryDirectory.appending(path: "petal-signing-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let config = """
            [req]
            distinguished_name = dn
            x509_extensions = ext
            prompt = no
            [dn]
            CN = Petal (Personal)
            [ext]
            basicConstraints = critical,CA:false
            keyUsage = critical,digitalSignature
            extendedKeyUsage = critical,codeSigning
            subjectKeyIdentifier = hash
            """
            try Data(config.utf8).write(to: work.appending(path: "cert.cnf"))
            let p = work.path
            let steps: [(String, [String])] = [
                ("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(p)/key.pem", "-out", "\(p)/cert.pem",
                                      "-days", "7300", "-config", "\(p)/cert.cnf"]),
                ("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", "\(p)/key.pem", "-in", "\(p)/cert.pem", "-out", "\(p)/id.p12",
                                      "-passout", "pass:\(password)", "-name", "Petal (Personal)"]),
            ] + PersonalSigning.make(keychain, password: password, identity: "\(p)/id.p12").map { (PersonalSigning.security, $0) }
            for (tool, arguments) in steps where run(tool, arguments).status != 0 {
                try? fm.removeItem(at: signing)
                throw Failure("Couldn't make Petal's signing certificate (\(URL(fileURLWithPath: tool).lastPathComponent) \(arguments[0]) failed).")
            }
        }
        let password = (try? String(contentsOf: passwordFile, encoding: .utf8)) ?? ""
        return try PersonalSigning.unlocked(keychain, password: password, run: { _ = run($0, $1) }) {
            // Self-made, so macOS lists it as untrusted; codesign signs with it all the same.
            let found = run(PersonalSigning.security, ["find-identity", keychain]).output.split(separator: "\n")
                .first { $0.contains("\"Petal (Personal)\"") }?.split(separator: " ").dropFirst().first
            guard let hash = found.map(String.init) else { throw Failure("Petal's signing certificate is missing from its keychain.") }
            return try body(keychain, hash)
        }
    }

    /// Signs a build of the person's Petal and puts it in place of this one. Petal restarts into it.
    nonisolated static func install(_ app: URL) throws {
        let entitlements = source.appending(path: "macos/Petal.entitlements").path
        // The keychain is locked again as soon as the build is signed, before anything is put in place.
        try withIdentity { keychain, hash in
            let sign = run("/usr/bin/codesign", ["--force", "--options", "runtime", "--entitlements", entitlements,
                                                 "--keychain", keychain, "--sign", hash, app.path])
            guard sign.status == 0, run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0 else {
                throw Failure("Couldn't sign the new Petal: \(sign.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
    }

    /// Back to the plain release of this version, signed as every release is.
    nonisolated static func reinstallRelease() throws {
        let tag = "macos-v\(version)"
        let work = FileManager.default.temporaryDirectory.appending(path: "petal-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let manifest = work.appending(path: "latest-macos.json"), zip = work.appending(path: "Petal.zip")
        guard run("/usr/bin/curl", ["-fsSL", "https://github.com/edgetr/petal/releases/download/\(tag)/latest-macos.json", "-o", manifest.path]).status == 0,
              let info = (try? Data(contentsOf: manifest)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let url = info["url"] as? String, let sha = info["sha256"] as? String,
              run("/usr/bin/curl", ["-fsSL", url, "-o", zip.path]).status == 0 else {
            throw Failure("Couldn't download Petal \(version) from GitHub.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha.lowercased() else { throw Failure("Petal \(version)'s download didn't match its checksum.") }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appending(path: "unpacked").path]).status == 0 else {
            throw Failure("Couldn't unpack Petal \(version).")
        }
        let app = work.appending(path: "unpacked/Petal.app")
        guard UpdateTrust.signed(app) else { throw Failure("Petal \(version)'s download isn't signed by Petal's maker, so it wasn't installed.") }
        guard UpdateTrust.release(app, is: version) else { throw Failure("The download isn't Petal \(version), so it wasn't installed.") }
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
    }

    // MARK: Updates

    /// Called by the updater when a newer release is out. Returns false when there are no changes of the person's
    /// own (the release's Petal.app is installed as usual); true when Petal was rebuilt with them. Throws, after
    /// telling the person, when it can't be done; this Petal keeps running either way.
    static func update(to release: Updater.Release, manual: Bool) async throws -> Bool {
        let version = release.version
        guard inUse, !isDevelopmentBuild else { return false }
        guard let tools = await Task.detached(operation: { developerTools }).value else {
            let message = "Your changes to Petal's code need Apple's command line tools to be rebuilt, and they aren't installed."
            if manual || !told.contains(version) {
                told.insert(version)
                installDeveloperTools()
                tell(version: version, message: message + " macOS is asking to install them; Petal tries again after.")
            }
            throw Failure(message)
        }
        let status = result(await Task.detached { core(["status", "--json"], tools: tools) }.value.output)
        if (status["changes"] as? Int ?? 0) == 0 && (status["unsaved"] as? [Any] ?? []).isEmpty { return false }
        let provider = PetalApp.shared.chatProvider
        let aiPath = provider.flatMap { PetalApp.shared.paths[$0] }
        // The release itself first, checked as one that's installed is (its checksum, its maker's signature, the
        // version it said): what's built with the person's changes is the source that Petal.app says it was built
        // from, by its commit, and no other.
        let commit = try await Updater.source(of: release)
        let arguments = ["update", "--version", version, "--commit", commit, "--json", "--check", buildCheck, "--keep", buildOutput] + (manual ? [] : ["--auto"])
        let reply = try await Task.detached { () throws -> [String: Any] in
            try? FileManager.default.removeItem(at: built)
            let reply = result(core(arguments, tools: tools, aiPath: aiPath).output)
            if reply["status"] as? String == "updated" {
                try install(built)
                _ = core(["mark-good"], tools: tools)
            }
            return reply
        }.value
        switch reply["status"] as? String {
        case "updated":
            return true
        case "kept":
            let message = reply["message"] as? String ?? "it stopped partway"
            if reply["again"] as? Bool != true || manual { tell(version: version, message: message, detail: reply["detail"] as? String ?? "") }
            throw Failure("Petal \(version) couldn't take your changes: \(message)")
        case "nothing":
            return false
        default:
            throw Failure(reply["message"] as? String ?? "Couldn't bring your changes over to Petal \(version).")
        }
    }

    /// Releases the person has already been told about this run (the check repeats every 6 hours).
    private static var told: Set<String> = []

    /// Tells the person plainly that they keep their own Petal, and offers to report it.
    static func tell(version: String, message: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = "Petal \(version) couldn't take your changes"
        alert.informativeText = "You still have your own Petal, with your changes, and nothing is lost.\n\n"
            + (message.split(separator: "\n").first.map(String.init) ?? message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Report…")
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        // A filled-in GitHub issue page: the person reads it, and submits it if they want to.
        let title = "Petal \(version) couldn't take my own changes to its code"
        var body = Doctor.reportBody(title + ": " + message, findings: Doctor.check(fix: false))
        if !detail.isEmpty { body += "\n\n<details><summary>Details</summary>\n\n```\n\(Doctor.redact(detail))\n```\n</details>" }
        var components = URLComponents(string: "https://github.com/\(Doctor.repo)/issues/new")!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    // MARK: petal doctor

    static func findings(fix: Bool) -> [Doctor.Finding] {
        guard exists, !isDevelopmentBuild else { return [] }
        guard let tools = developerTools else {
            if fix { installDeveloperTools() }
            return [Doctor.Finding(level: inUse ? "error" : "warn", area: "code",
                                   text: "Your changes to Petal's code need Apple's command line tools, which aren't installed: updates can't bring them along.",
                                   fixed: fix ? "asked macOS to install them" : nil, fixable: true)]
        }
        let output = core(["doctor"] + (fix ? ["--fix"] : []), tools: tools).output
        guard let line = output.split(separator: "\n").last,
              let list = try? JSONDecoder().decode([Doctor.Finding].self, from: Data(line.utf8)) else {
            return [Doctor.Finding(level: "warn", area: "code", text: "Couldn't check your changes to Petal's code: \(output.suffix(160))")]
        }
        return list
    }

    // MARK: petal personal …

    nonisolated static let help = """
    petal personal init                  set up Petal's source to change (once), and print where it is
    petal personal status | list         your changes, unsaved edits and the last update
    petal personal save "<what changed>" build, keep and use your edits (it restarts Petal into them)
    petal personal undo [<n>]            take out unsaved edits, or the n-th newest change
    petal personal reset                 back to plain Petal releases (your changes stay in a backup)
    petal personal restore [<backup>]    bring a backup back
    petal personal retry                 try bringing your changes over to the newest Petal again
    """

    nonisolated static func command(_ arguments: [String]) -> Never {
        let command = arguments.first ?? "status"
        let rest = Array(arguments.dropFirst())
        setvbuf(stdout, nil, _IOLBF, 0)   // in order with the core's output, even through a pipe
        if ["help", "-h", "--help"].contains(command) { print(help); exit(0) }
        guard Bundle.main.path(forResource: "petal-personal", ofType: nil, inDirectory: "personal") != nil else {
            CLI.fail("This Petal.app is missing its petal-personal script; reinstall Petal.")
        }
        if isDevelopmentBuild {
            CLI.fail("This Petal is built from a source checkout (\(Bundle.main.bundlePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))): change that checkout, and build it with macos/build.sh.")
        }
        guard let tools = developerTools else {
            installDeveloperTools()
            CLI.fail("Changing Petal's code needs Apple's command line tools (git, Swift). macOS is asking to install them now; run this again once they're in.")
        }
        func pass(_ arguments: [String]) -> Int32 { core(arguments, tools: tools, echo: true).status }
        func finish(_ status: Int32) -> Never {
            guard status == 0 else { exit(status) }
            if FileManager.default.fileExists(atPath: built.path) {
                print("Installing it…")
                do { try install(built) } catch { CLI.fail(error.localizedDescription) }
                _ = core(["mark-good"], tools: tools)
                print(restart())
            }
            exit(0)
        }
        try? FileManager.default.removeItem(at: built)
        let build = ["--check", buildCheck, "--keep", buildOutput]
        switch command {
        case "save", "undo":
            if command == "save" { print("Building Petal with your edits (a minute or two)…") }
            finish(pass([command] + rest + build))
        case "retry":
            let failed = state["failed"] as? [String: Any]
            let target = (failed?["version"] as? String) ?? version
            // The release that couldn't take them: the same source again, by the commit kept with it.
            let commit = (failed?["commit"] as? String).flatMap { UpdateTrust.plainCommit($0) ? ["--commit", $0] : nil } ?? []
            print("Bringing your changes over to Petal \(target) and building it…")
            finish(pass(["update", "--version", target] + commit + build))
        case "restore":
            let status = pass(["restore"] + rest)
            guard status == 0 else { exit(status) }
            print("Building it…")
            finish(pass(["update", "--version", version] + build))
        case "reset":
            let status = pass(["reset"])
            guard status == 0 else { exit(status) }
            print("Putting back plain Petal \(version)…")
            do { try reinstallRelease() } catch { CLI.fail(error.localizedDescription) }
            print(restart())
            exit(0)
        default:
            exit(pass([command] + rest))
        }
    }

    /// Restarts the running Petal into the one just installed.
    nonisolated static func restart() -> String {
        if testing != nil { return "Done (PETAL_PERSONAL_HOME is set, so no Petal was restarted)." }
        let answer = MCP.petal("restart")
        return answer == "Petal isn't running" ? "Done. Open Petal to use it." : "Done. Petal is restarting with it."
    }

    // MARK: Running things

    nonisolated static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, echo: Bool = false) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        if echo {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            guard (try? process.run()) != nil else { return (-1, "") }
            process.waitUntilExit()
            return (process.terminationStatus, "")
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
