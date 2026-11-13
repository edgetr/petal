import Foundation

/// What's New after Petal updated itself: which versions' notes open by themselves when Petal starts, and which part
/// of a version's notes the app shows. Pure (versions by `UpdateTrust`'s rules), checked by `macos/checks/run.sh`.
/// The notes are `macos/notes/<version>.md`, which `build.sh` copies into the app (`Resources/notes/`) and the
/// release workflow makes each release's text.
enum WhatsNew {
    /// The versions whose notes open by themselves now, newest first; none when nothing should open.
    /// - `last`: the version Petal last ran as on this Mac (`state.json`'s `lastVersion`), nil when it was never kept.
    /// - `running`: this Petal's version.
    /// - `welcomed`: the welcome was finished once (`dock.json`'s `welcomed`).
    /// - `carried`: the versions whose notes this app holds.
    ///
    /// A first install (not welcomed) shows nothing: the welcome is what it sees. No record but welcomed is a Petal
    /// from before this was kept, updated: it shows the running version's notes only. A newer version than the one
    /// kept shows each version carried since, up to this one, and this one always (its notes are fetched when the app
    /// doesn't hold them). The same version, an older one, or a version that isn't plain numbers shows nothing.
    static func versions(last: String?, running: String, welcomed: Bool, carried: [String]) -> [String] {
        guard welcomed, UpdateTrust.plainVersion(running) else { return [] }
        guard let last, UpdateTrust.plainVersion(last) else { return [running] }
        guard UpdateTrust.newer(running, than: last) else { return [] }
        let missed = carried.filter {
            UpdateTrust.plainVersion($0) && UpdateTrust.newer($0, than: last) && !UpdateTrust.newer($0, than: running)
                && !same($0, running)
        }
        return [running] + Set(missed).sorted { UpdateTrust.newer($0, than: $1) }
    }

    /// Whether this start should be kept as the last version Petal ran as: whenever it's a plain version and differs
    /// from the one kept, so What's New opens once for a version, and a first install or going back to an older one
    /// is kept too (the next update compares with it).
    static func keeps(last: String?, running: String) -> Bool {
        UpdateTrust.plainVersion(running) && (last.map { !same($0, running) } ?? true)
    }

    /// "2.1" and "2.1.0" are the same version.
    static func same(_ a: String, _ b: String) -> Bool { !UpdateTrust.newer(a, than: b) && !UpdateTrust.newer(b, than: a) }

    /// The line in a notes file after which everything is for the release page only (what someone downloading needs:
    /// macOS 26, Open Anyway). The release page doesn't show it (an HTML comment); the app shows nothing from it on.
    static let releasePageOnly = "<!-- Release page only: the app leaves out what follows. -->"

    /// What the app shows of a version's notes: everything before `releasePageOnly`, without blank lines at the end.
    /// Notes without it are shown whole.
    static func inApp(_ notes: String) -> String {
        var kept: [Substring] = []
        for line in notes.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(releasePageOnly) == .orderedSame { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The version a carried notes file is for ("2.1.3.md"), or nil for anything else in the folder.
    static func version(ofFile name: String) -> String? {
        guard name.hasSuffix(".md") else { return nil }
        let version = String(name.dropLast(3))
        return UpdateTrust.plainVersion(version) ? version : nil
    }
}
