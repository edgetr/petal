import AppKit
import CryptoKit
import Observation

/// Updates from GitHub Releases, as get.sh does on Omarchy: 2 minutes after launch, then every 6 hours, while
/// autoUpdate is on. macOS releases have their own tags (macos-vX.Y.Z) and carry latest-macos.json:
/// {"version": "X.Y.Z", "url": "<zip>", "sha256": "<hex>"}. The new Petal.app replaces this one in place, and a card
/// offers to restart. A build run from a source checkout is never updated.
@MainActor @Observable
final class Updater {
    private(set) var status = ""
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

    func check(manual: Bool) {
        guard manual || PetalApp.shared.config.bool("autoUpdate"), !checking else { return }
        guard !isDevelopmentBuild else {
            status = "This Petal was built from source; it doesn't update itself."
            return
        }
        checking = true
        status = "Checking…"
        Task {
            defer { checking = false }
            do {
                guard let latest = try await Self.latest() else { status = "No Mac release yet."; return }
                let current = PetalApp.shared.version
                guard Self.newer(latest.version, than: current) else { status = "Petal \(current) is the newest."; return }
                status = "Downloading Petal \(latest.version)…"
                // With the person's own changes to Petal's code, it's rebuilt with them instead (Personal.swift).
                if try await !Personal.update(to: latest.version, manual: manual) { try await install(latest) }
                status = "Petal \(latest.version) is ready. Restart Petal to finish."
                PetalApp.shared.popups.show(FocusCard(kind: .update, version: latest.version))
            } catch {
                status = "Couldn't update: \(error.localizedDescription)"
            }
        }
    }

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
        return Release(version: version, url: url, sha256: sha.lowercased())
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func install(_ release: Release) async throws {
        let (file, _) = try await URLSession.shared.download(from: release.url)
        let bundle = Bundle.main.bundleURL
        // Checking, unpacking and swapping take a moment; none of it on the dock's thread.
        try await Task.detached { try Self.swap(in: file, release: release, over: bundle) }.value
    }

    nonisolated private static func swap(in file: URL, release: Release, over bundle: URL) throws {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw UpdateError("the download didn't match its checksum") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "petal-update-\(release.version)")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", file.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = folder.appending(path: "Petal.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("the download had no Petal.app")
        }
        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
    }

    struct UpdateError: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
