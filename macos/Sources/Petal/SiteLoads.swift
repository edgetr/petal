import Foundation

/// Reads of website shortcuts' cached icons under way (Sites.swift), each with whoever waits for its answer, without
/// AppKit (checked by checks/SiteLoadsCheck.swift).
struct SiteLoads {
    private var waiting: [String: [@MainActor (Bool) -> Void]] = [:]

    /// Asks for `host`'s read: true when none was under way (start it now); either way `then`, if given, hears the
    /// answer when that read is done.
    mutating func ask(_ host: String, then: (@MainActor (Bool) -> Void)?) -> Bool {
        let first = waiting[host] == nil
        waiting[host, default: []] += then.map { [$0] } ?? []
        return first
    }

    /// `host`'s read is done: everyone who waited for it, to be told the answer; the next ask starts a new read.
    mutating func answered(_ host: String) -> [@MainActor (Bool) -> Void] {
        waiting.removeValue(forKey: host) ?? []
    }
}
