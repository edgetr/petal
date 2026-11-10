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
    /// Stack folders with something new since the stack was last opened: a dot on the stack.
    private(set) var fresh: Set<String> = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subscribers: [Any] = []
    @ObservationIgnored private var active: [ObjectIdentifier: (folder: String, progress: Progress)] = [:]
    @ObservationIgnored private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var asking = false

    @ObservationIgnored private var watched: [String] = []
    /// When each stack was last opened (seconds since 1970), kept in state.json.
    @ObservationIgnored private var seen: [String: Double]?
    @ObservationIgnored private var newest: [String: Date] = [:]
    /// The Trash is looked at now and then when the kernel can't watch it for Petal (no Full Disk Access).
    @ObservationIgnored private var trashPolled = false
    @ObservationIgnored private lazy var folders = FolderWatcher("petal.folders") { [weak self] folder, watching in
        // On the watcher's queue: the disk is read here, the dock is told on the main thread.
        if folder == Stacks.trashFolder {
            let empty = Stacks.trashIsEmpty()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trashRead(empty, watching: watching) } }
        } else {
            let date = Stacks.newest(folder)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.folderRead(folder, newest: date) } }
        }
    }

    /// Watches the stack folders for downloads and new files again when they change.
    func watch(_ folders: [String]) {
        guard folders != watched else { return }
        watched = folders
        watchDownloads(in: folders)
        watchStackFolders()
    }

    func start(watchFolders: [String]) {
        timer?.invalidate()
        watched = watchFolders
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        watchDownloads(in: watchFolders)
        // When each stack was last opened, read before the folders are.
        folders.queue.async {
            let saved = PetalState.read()["stacksSeen"] as? [String: Double] ?? [:]
            DispatchQueue.main.async { MainActor.assumeIsolated { self.seen = saved } }
        }
        watchStackFolders()
    }

    private func watchStackFolders() {
        folders.watch(watched + [Stacks.trashFolder])
    }

    private func poll() {
        tick += 1
        if tick % 2 == 0 { readBadges() }
        if trashPolled && tick % 5 == 0 { folders.look(Stacks.trashFolder) }
        if tick % 2 == 1 && !asking { askNowPlaying() }
    }

    /// Apple events wait for a busy player, so they never run on the dock's thread.
    private func askNowPlaying() {
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

    /// The music controls: "previous track", "playpause" or "next track", sent to the player off the main thread.
    /// Play and pause show at once; the player is asked again right after the command (the same queue, so in order),
    /// so a new song shows without waiting for the next look.
    func control(_ command: String) {
        guard let playing = nowPlaying else { return }
        NowPlaying.send(command, to: playing.player)
        if command == "playpause" {
            nowPlaying = NowPlaying(player: playing.player, title: playing.title, artist: playing.artist, playing: !playing.playing,
                                    artwork: playing.artwork)
        }
        askNowPlaying()
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
                let data = NSAppleScript(source: "if application \"Music\" is running then tell application \"Music\" to get raw data of artwork 1 of current track")?
                    .executeAndReturnError(&error).data
                DispatchQueue.main.async { MainActor.assumeIsolated { self.artwork = data.flatMap(NSImage.init(data:)) } }
            }
        } else {
            artwork = nil
        }
    }

    func clearBadge(_ id: String) { badges[id] = nil }

    // MARK: Stacks and the Trash

    private func trashRead(_ empty: Bool?, watching: Bool) {
        // Listed and watched: the kernel says when it changes. Otherwise Finder answers now and then, or nobody can.
        trashPolled = !watching || empty == nil
        let now = empty ?? true
        if now != trashEmpty { trashEmpty = now }
    }

    private func folderRead(_ folder: String, newest date: Date?) {
        newest[folder] = date
        if seen?[folder] == nil {
            // A stack Petal hasn't seen before starts with nothing new: what's there already isn't news.
            seen?[folder] = Date().timeIntervalSince1970
            saveSeen()
        }
        updateFresh()
        // An open stack follows its folder.
        if let open = PetalApp.shared.popups.stack, open.folder == folder {
            open.load { PetalApp.shared.popups.refit() }
            opened(folder)
        }
    }

    /// The person looked in a stack: what's in it isn't new any more.
    func opened(_ folder: String) {
        seen?[folder] = Date().timeIntervalSince1970
        saveSeen()
        updateFresh()
    }

    private func updateFresh() {
        guard let seen else { return }
        let now = Set(watched.filter { folder in
            guard let date = newest[folder], let last = seen[folder] else { return false }
            return date.timeIntervalSince1970 > last
        })
        if now != fresh { fresh = now }
    }

    private func saveSeen() {
        guard let seen else { return }
        folders.queue.async { PetalState.set("stacksSeen", seen) }
    }

    /// The Trash after something is dropped on it or it's emptied, without waiting for the next look.
    func lookAtTrash() { folders.look(Stacks.trashFolder) }

    /// What `Petal --snapshot` draws the dock with.
    func preview(trashEmpty: Bool, fresh: Set<String>, nowPlaying: NowPlaying?) {
        self.trashEmpty = trashEmpty
        self.fresh = fresh
        self.nowPlaying = nowPlaying
    }

    /// Bounces an app once (IPC testBounce).
    func bounce(_ id: String) { bounces[id, default: 0] += 1 }

    // MARK: Badges

    /// Apps set their badge on macOS's Dock, and the Dock shows it to Accessibility as each item's status label.
    /// Petal reads it there; macOS's Dock keeps running, hidden, while Petal replaces it.
    /// Reads macOS's Dock's badges through Accessibility (a call to the Dock for each of its items), off the main
    /// thread, so the dock and Petal's windows never wait on it.
    private func readBadges() {
        guard !readingBadges else { return }
        readingBadges = true
        Self.badgeQueue.async {
            let found = Self.dockBadges()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.readingBadges = false
                    guard let found else { return }
                    for (id, label) in found where Self.count(label) > Self.count(self.badges[id] ?? "") {
                        self.bounces[id, default: 0] += 1
                    }
                    if found != self.badges { self.badges = found }
                }
            }
        }
    }
    @ObservationIgnored private var readingBadges = false
    nonisolated private static let badgeQueue = DispatchQueue(label: "petal.badges", qos: .utility)

    /// Each app's badge in macOS's Dock, by bundle id; nil without Accessibility or the Dock.
    nonisolated private static func dockBadges() -> [String: String]? {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
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
        return found
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
            // Foundation may call these on any thread.
            let subscriber = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.track(progress, in: folder) } }
                return { [weak self] in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.untrack(progress) } }
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
        let rounded = byFolder.mapValues { (($0.done / max(1, $0.count)) * 50).rounded() / 50 }
        if rounded != progress { progress = rounded }
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
            if application "\(app)" is not running then return ""
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
            NSAppleScript(source: "if application \"\(app)\" is running then tell application \"\(app)\" to \(command)")?
                .executeAndReturnError(&error)
        }
    }
}
