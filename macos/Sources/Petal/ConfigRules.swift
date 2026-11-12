import Foundation

/// How Petal reads its own files in ~/.config/petal, as rules without AppKit (checked by checks/ConfigRulesCheck.swift):
/// a file someone is editing is never taken for an empty one.
enum ConfigRules {
    /// The dock's apps as dock.json lists them: each entry that is text, trimmed, in order. Anything else in the list
    /// (a number, null, an object left by a hand edit) is passed over, never taken for an empty dock, so a change made
    /// afterwards keeps every app that was there.
    static func apps(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A file read again: what it holds, nothing when it isn't there any more, and what was read before when it's
    /// there but doesn't read as JSON (an editor halfway through writing it, a typo), until it does again.
    static func reread(_ parsed: [String: Any]?, exists: Bool, before: [String: Any]) -> [String: Any] {
        if let parsed { return parsed }
        return exists ? before : [:]
    }
}
