import Foundation

/// How Petal reads its own files in ~/.config/petal, as rules without AppKit (checked by checks/ConfigRulesCheck.swift):
/// a file someone is editing is never taken for an empty one, and what Petal AI may do grows only in Petal itself.
enum ConfigRules {
    /// The dock's apps as dock.json lists them: each entry that is text, trimmed, in order. Anything else in the list
    /// (a number, null, an object left by a hand edit) is passed over, never taken for an empty dock, so a change made
    /// afterwards keeps every app that was there.
    static func apps(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The furthest any number setting is taken from 0. No setting means anything near it, and everything that rounds
    /// a setting to a whole number (a slider's label, the displays' limit) traps on one past Int's range.
    static let numberBound = 1_000_000.0

    /// A number setting as Petal goes by it: the file's number (a JSON true or false counts as 1 or 0), else the
    /// default, and one written by hand past `numberBound` either way taken as that bound.
    static func number(_ value: Any?, default fallback: Any?) -> Double {
        let read = (value as? NSNumber)?.doubleValue ?? (fallback as? NSNumber)?.doubleValue ?? 0
        return read.isFinite ? min(numberBound, max(-numberBound, read)) : 0
    }

    /// A file read again: what it holds, nothing when it isn't there any more, and what was read before when it's
    /// there but doesn't read as JSON (an editor halfway through writing it, a typo), until it does again.
    static func reread(_ parsed: [String: Any]?, exists: Bool, before: [String: Any]) -> [String: Any] {
        if let parsed { return parsed }
        return exists ? before : [:]
    }

    /// The settings that say how far Petal AI may go without the person: Full access (`claudeAccess`), using their
    /// apps (`computerUse`), what's allowed without asking (`aiAllowed`) and the apps it never looks into
    /// (`aiNeverLook`). They widen only in Petal itself: its settings window, the chat's options, Always on a card.
    static let personsOwn = ["claudeAccess", "computerUse", "aiAllowed", "aiNeverLook"]

    /// settings.json read again while Petal runs (`disk`), beside what Petal goes by now (`memory`): what to take.
    /// Everything in the file is taken as it is, but a change to one of `personsOwn` that would let Petal AI do
    /// more: Full access turned on, using apps turned on, a kind added to what's allowed, an app taken off the
    /// private list. That one stays as Petal has it (`refused` names it, and the file is written to say so again);
    /// a change that lets it do less is taken like any other. `defaults`: what a missing key means.
    static func taken(_ disk: [String: Any], over memory: [String: Any], defaults: [String: Any]) -> (settings: [String: Any], refused: [String]) {
        var settings = disk
        var refused: [String] = []
        let full = { (from: [String: Any]) in (from["claudeAccess"] as? String ?? defaults["claudeAccess"] as? String) == "full" }
        if full(disk), !full(memory) {
            settings["claudeAccess"] = memory["claudeAccess"]
            refused.append("claudeAccess")
        }
        let uses = { (from: [String: Any]) in from["computerUse"] as? Bool ?? defaults["computerUse"] as? Bool ?? false }
        if uses(disk), !uses(memory) {
            settings["computerUse"] = memory["computerUse"]
            refused.append("computerUse")
        }
        let list = { (from: [String: Any], key: String) in from[key] as? [String] ?? defaults[key] as? [String] ?? [] }
        // Allowed without asking: what the file adds is left out; what it takes away stays away.
        let allowed = list(disk, "aiAllowed"), had = Set(list(memory, "aiAllowed"))
        if !Set(allowed).isSubset(of: had) {
            settings["aiAllowed"] = allowed.filter(had.contains)
            refused.append("aiAllowed")
        }
        // Kept private: what the file takes off the list is put back; what it adds stays on.
        let hidden = list(disk, "aiNeverLook")
        let missing = list(memory, "aiNeverLook").filter { !hidden.contains($0) }
        if !missing.isEmpty {
            settings["aiNeverLook"] = hidden + missing
            refused.append("aiNeverLook")
        }
        return (settings, refused)
    }
}
