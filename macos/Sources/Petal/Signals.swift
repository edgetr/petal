import AppKit
import ApplicationServices
import Observation

/// What apps signal to the dock, the macOS side of Signals.qml: unread badges, download progress and what's playing.
@MainActor @Observable
final class Signals {
    /// Badge text by bundle id ("3", "•").
    private(set) var badges: [String: String] = [:]
    /// Apps whose badge just went up: the dock bounces each once.
    private(set) var bounces: [String: Int] = [:]
    /// Downloads in progress, 0–1, by the folder they land in (the stack's path, with ~).
    private(set) var progress: [String: Double] = [:]
    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var trashEmpty = true

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subscribers: [Any] = []
    @ObservationIgnored private var active: [ObjectIdentifier: (folder: String, progress: Progress)] = [:]
    @ObservationIgnored private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var asking = false

    func start(watchFolders: [String]) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        watchDownloads(in: watchFolders)
    }

    private func poll() {
        tick += 1
        if tick % 2 == 0 {
            readBadges()
            let empty = Stacks.trashIsEmpty
            if empty != trashEmpty { trashEmpty = empty }
        }
        if tick % 2 == 1 && !asking {
            // Apple events wait for a busy player, so they never run on the dock's thread.
            asking = true
            NowPlaying.queue.async {
                let current = NowPlaying.current()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.asking = false
                        if current != self.nowPlaying {
                            let newTrack = current?.title != self.nowPlaying?.title || current?.player != self.nowPlaying?.player
                            self.nowPlaying = current
                            if newTrack { self.loadArtwork(current) }
                        }
                    }
                }
            }
        }
    }

    /// Spotify gives a link to the cover; Music gives the picture itself.
    private func loadArtwork(_ playing: NowPlaying?) {
        guard let playing else { artwork = nil; return }
        if let url = playing.artwork {
            Task {
                let data = try? await URLSession.shared.data(from: url).0
                artwork = data.flatMap(NSImage.init(data:))
            }
        } else if playing.player == "com.apple.Music" {
            NowPlaying.queue.async {
                var error: NSDictionary?
                let data = NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")?
                    .executeAndReturnError(&error).data
                DispatchQueue.main.async { MainActor.assumeIsolated { self.artwork = data.flatMap(NSImage.init(data:)) } }
            }
        } else {
            artwork = nil
        }
    }

    func clearBadge(_ id: String) { badges[id] = nil }

    /// Bounces an app once (IPC testBounce).
    func bounce(_ id: String) { bounces[id, default: 0] += 1 }

    // MARK: Badges

    /// Apps set their badge on macOS's Dock, and the Dock shows it to Accessibility as each item's status label.
    /// Petal reads it there; macOS's Dock keeps running, hidden, while Petal replaces it.
    private func readBadges() {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var found: [String: String] = [:]
        for list in Windows.value(element, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
            for item in Windows.value(list, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
                guard let label: String = Windows.value(item, "AXStatusLabel"), !label.isEmpty,
                      let url: URL = Windows.value(item, kAXURLAttribute), let id = Bundle(url: url)?.bundleIdentifier else { continue }
                found[id] = label
            }
        }
        for (id, label) in found where Self.count(label) > Self.count(badges[id] ?? "") {
            bounces[id, default: 0] += 1
        }
        if found != badges { badges = found }
    }

    private static func count(_ label: String) -> Int { Int(label) ?? (label.isEmpty ? 0 : 1) }

    // MARK: Download progress

    /// Browsers and Finder publish a file's progress while it downloads or copies; anything landing in a stack's
    /// folder shows as a ring on that stack.
    private func watchDownloads(in folders: [String]) {
        for subscriber in subscribers { Progress.removeSubscriber(subscriber) }
        subscribers = []
        for folder in folders {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            let subscriber = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
                MainActor.assumeIsolated { self?.track(progress, in: folder) }
                return { [weak self] in
                    MainActor.assumeIsolated { self?.untrack(progress) }
                }
            }
            subscribers.append(subscriber)
        }
    }

    private func track(_ item: Progress, in folder: String) {
        let key = ObjectIdentifier(item)
        active[key] = (folder, item)
        observations[key] = item.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateProgress() } }
        }
        updateProgress()
    }

    private func untrack(_ item: Progress) {
        let key = ObjectIdentifier(item)
        active[key] = nil
        observations[key] = nil
        updateProgress()
    }

    private func updateProgress() {
        var byFolder: [String: (done: Double, count: Double)] = [:]
        for (_, entry) in active where !entry.progress.isFinished {
            byFolder[entry.folder, default: (0, 0)].done += max(0, entry.progress.fractionCompleted)
            byFolder[entry.folder, default: (0, 0)].count += 1
        }
        progress = byFolder.mapValues { $0.done / max(1, $0.count) }
    }
}

/// The track playing in Music or Spotify. macOS keeps its system-wide now playing to Apple's own apps, so Petal
/// asks the two players directly; macOS asks the person once before Petal may (Automation).
struct NowPlaying: Equatable {
    let player: String   // bundle id
    let title: String
    let artist: String
    let playing: Bool
    let artwork: URL?

    static let players = ["com.spotify.client", "com.apple.Music"]
    static let queue = DispatchQueue(label: "petal.nowplaying")

    nonisolated static func current() -> NowPlaying? {
        for id in players where NSRunningApplication.runningApplications(withBundleIdentifier: id).first != nil {
            let app = id == "com.spotify.client" ? "Spotify" : "Music"
            let artwork = id == "com.spotify.client" ? "artwork url of current track" : "\"\""
            let script = """
            tell application "\(app)"
              if player state is stopped then return ""
              set sep to ASCII character 31
              return (name of current track) & sep & (artist of current track) & sep & (player state as text) & sep & \(artwork)
            end tell
            """
            var error: NSDictionary?
            guard let text = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue, !text.isEmpty else { continue }
            let parts = text.components(separatedBy: "\u{1F}")
            guard parts.count >= 3 else { continue }
            return NowPlaying(player: id, title: parts[0], artist: parts[1], playing: parts[2] == "playing",
                              artwork: parts.count > 3 ? URL(string: parts[3]) : nil)
        }
        return nil
    }

    /// "playpause", "next track", "previous track".
    static func send(_ command: String, to player: String) {
        let app = player == "com.spotify.client" ? "Spotify" : "Music"
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(app)\" to \(command)")?.executeAndReturnError(&error)
        }
    }
}
