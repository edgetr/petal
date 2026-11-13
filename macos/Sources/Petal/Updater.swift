import AppKit
import CryptoKit
import Observation

/// Updates from GitHub Releases: 2 minutes after launch, then every 6 hours, while autoUpdate is on. Petal's
/// releases are the tags macos-vX.Y.Z, and each carries latest-macos.json:
/// {"version": "X.Y.Z", "url": "<zip>", "sha256": "<hex>"}. The new Petal.app replaces this one in place, and the menu bar
/// offers to restart. With autoUpdate off, a check the person asks for stops at "available" (`available`), and the
/// update is installed only when they press Install. A build run from a source checkout is never updated.
@MainActor @Observable
final class Updater {
    private(set) var status = ""
    /// A new Petal is installed and waits for a restart: the menu bar icon shows a dot and offers it.
    var ready: String?
    /// A newer Petal found by a check the person asked for while autoUpdate is off: nothing is downloaded until they
    /// press Install (`installAvailable`).
    private(set) var available: Release?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checking = false

    static let releases = URL(string: "https://api.github.com/repos/edgetr/petal/releases?per_page=100")!

    var isDevelopmentBuild: Bool { Bundle.main.bundlePath.contains("/macos/build/") }

    func start() {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(manual: false) }
        }
    }

    func check(manual: Bool, install wanted: Bool = false) {
        guard manual || PetalApp.shared.config.bool("autoUpdate"), !checking else { return }
        guard !isDevelopmentBuild else {
            status = "This copy of Petal doesn't update itself."
            return
        }
        checking = true
        status = "Checking…"
        Task {
            defer { checking = false }
            let found: Release?
            do { found = try await Self.latest() } catch { found = nil }
            guard let latest = found else { status = "Couldn’t check for updates. Try again later."; return }
            let current = PetalApp.shared.version
            guard Self.newer(latest.version, than: current) else { available = nil; status = "You have the newest Petal, \(current)."; return }
            // Already downloaded and in place: asking again never downloads it a second time.
            guard ready != latest.version else { status = "Petal \(latest.version) is ready. Restart Petal to finish."; return }
            // Updates off: the person decides, after seeing what's new in it. The setting as it is now, after the
            // network's waits, not as it was when the check began; Install is the person's own say.
            guard wanted || PetalApp.shared.config.bool("autoUpdate") else {
                available = latest
                status = "Petal \(latest.version) is available."
                return
            }
            do {
                status = "Downloading Petal \(latest.version)…"
                // With the person's own changes to Petal's code, it's rebuilt with them instead (Personal.swift).
                if try await !Personal.update(to: latest, manual: manual),
                   try await !install(latest, stillWanted: { wanted || PetalApp.shared.config.bool("autoUpdate") }) {
                    // Turned off while it downloaded: it waits for the person's Install, as any update does then.
                    available = latest
                    status = "Petal \(latest.version) is available."
                    return
                }
                status = "Petal \(latest.version) is ready. Restart Petal to finish."
                available = nil
                ready = latest.version
            } catch {
                status = "Couldn't update: \(error.localizedDescription)"
            }
        }
    }

    /// Installs the update a check found while autoUpdate was off: the newest release is looked up again and checked as
    /// every update is.
    func installAvailable() { check(manual: true, install: true) }

    struct Release: Sendable { let version: String; let url: URL; let sha256: String }

    private static func latest() async throws -> Release? {
        var request = URLRequest(url: releases)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        guard let release = list.first(where: {
            ($0["tag_name"] as? String)?.hasPrefix("macos-v") == true && $0["draft"] as? Bool != true && $0["prerelease"] as? Bool != true
        }) else { return nil }
        let assets = release["assets"] as? [[String: Any]] ?? []
        guard let manifest = assets.first(where: { $0["name"] as? String == "latest-macos.json" })?["browser_download_url"] as? String,
              let manifestURL = URL(string: manifest) else { return nil }
        let (body, _) = try await URLSession.shared.data(from: manifestURL)
        guard let info = try JSONSerialization.jsonObject(with: body) as? [String: Any], let version = info["version"] as? String,
              let link = info["url"] as? String, let url = URL(string: link), let sha = info["sha256"] as? String else { return nil }
        // Its version is used in what's downloaded and where it's unpacked: plain numbers only, or nothing is.
        guard UpdateTrust.plainVersion(version) else { throw UpdateError("the newest release's version isn't one Petal can read") }
        return Release(version: version, url: url, sha256: sha.lowercased())
    }

    static func newer(_ a: String, than b: String) -> Bool { UpdateTrust.newer(a, than: b) }

    /// Downloads the release and puts it in place, unless `stillWanted` (asked once the download is here, right before
    /// anything is replaced) says the person turned updates off meanwhile: then nothing is replaced, and it's false.
    private func install(_ release: Release, stillWanted: () -> Bool) async throws -> Bool {
        let (file, _) = try await URLSession.shared.download(from: release.url)
        guard stillWanted() else {
            try? FileManager.default.removeItem(at: file)
            return false
        }
        let bundle = Bundle.main.bundleURL
        let running = PetalApp.shared.version
        // Checking, unpacking and swapping take a moment; none of it on the dock's thread.
        try await Task.detached { try Self.swap(in: file, release: release, over: bundle, running: running) }.value
        return true
    }

    /// The commit a release was built from, for an update rebuilt with the person's own changes (Personal.update):
    /// the release's Petal.app is downloaded and checked exactly as one that's installed is, and the commit is the
    /// one that app says (`UpdateTrust.source`). Nothing is installed.
    static func source(of release: Release) async throws -> String {
        let (file, _) = try await URLSession.shared.download(from: release.url)
        let running = PetalApp.shared.version
        return try await Task.detached {
            defer { try? FileManager.default.removeItem(at: file) }
            return try Self.checked(file, release: release, running: running) { app in
                guard let commit = UpdateTrust.source(of: app, is: release.version, over: running) else {
                    throw UpdateError("Petal \(release.version) doesn't say which source it was built from, so your changes couldn't be brought over")
                }
                return commit
            }
        }.value
    }

    nonisolated private static func swap(in file: URL, release: Release, over bundle: URL, running: String) throws {
        try checked(file, release: release, running: running) { app in
            // Checked where it was unpacked; what's in place now is looked at once more.
            guard try UpdateTrust.install(app, in: bundle, is: release.version, over: running) else {
                throw UpdateError("what was put in place isn't the Petal \(release.version) that was checked. Check for updates again before restarting Petal")
            }
        }
    }

    /// A release's download, checked: it matches its checksum, and the Petal.app in it is signed by Petal's maker
    /// and is the version its release said, newer than the one running. `use` gets that app in a folder of its own,
    /// which goes afterwards.
    nonisolated private static func checked<T>(_ file: URL, release: Release, running: String, _ use: (URL) throws -> T) throws -> T {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw UpdateError("the download didn't arrive whole") }
        // A folder of its own, named by nothing the release says.
        let folder = FileManager.default.temporaryDirectory.appending(path: "petal-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", file.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = folder.appending(path: "Petal.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("the download had no Petal in it")
        }
        // The checksum came with the download; the signature can't be made by whoever made the download. And it must
        // be the very version its release said, newer than this one: never an older build of the maker's.
        guard UpdateTrust.signed(app) else { throw UpdateError("the download isn't signed by Petal's maker, so it wasn't installed") }
        guard UpdateTrust.update(app, is: release.version, over: running) else {
            throw UpdateError("the download isn't the Petal \(release.version) its release said, so it wasn't installed")
        }
        return try use(app)
    }

    struct UpdateError: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
