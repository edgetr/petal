import Foundation

/// What Petal Notes' tools give an agent, with the vault's secrets taken out: every string in the answer (a note's
/// text, title, preview, notebook, places, a file's name) goes through the redaction `petal_ui` and `petal_look` use
/// (`UIMap.SecretIndex.redacted`). While the vault can't be read nothing is answered (nil): an agent is told that,
/// never given text Petal couldn't check. Off the main thread (the index may read the Keychain).
enum NoteShield {
    static let unreadable = "Your vault can't be read right now, so Petal can't check these notes for saved secrets: nothing was shown."

    static func shield(_ value: Any, index: UIMap.SecretIndex) -> Any? {
        guard !index.unreadable else { return nil }
        return clean(value, index)
    }

    /// The notes a search finds (their places in `texts`), matched only on what the agent may see of each (redacted
    /// with a settled index): whether a note matches never says anything about a secret's characters, so searching
    /// longer and longer prefixes of a card number or PIN finds nothing. Nil while the vault can't be read.
    static func search(_ query: String, in texts: [String], index: UIMap.SecretIndex, matches: (String, String) -> Bool) -> [Int]? {
        guard !index.unreadable else { return nil }
        return texts.indices.filter { matches(query, index.redacted(texts[$0])) }
    }

    enum Lookup: Equatable { case found(Int), none, unreadable }

    /// The note an agent names (`rows`: each note's id, file path and text, and whether it's a version): its id, its
    /// path or its title, each compared exactly as the tools tell them (NoteTold: derived after redaction), never
    /// the raw text, so naming a guess can't tell whether a secret is in a title or file name.
    static func find(_ name: String, rows: [(id: String, key: String, body: String, version: Bool)], index: UIMap.SecretIndex) -> Lookup {
        guard !index.unreadable else { return .unreadable }
        let redact = { (text: String) in index.redacted(text) }
        let shown = rows.map { (id: NoteTold.id($0.id, body: $0.body, redact), key: NoteTold.path($0.key, body: $0.body, redact),
                                title: NoteTold.title($0.body, redact), version: $0.version) }
        if let at = shown.firstIndex(where: { !$0.version && $0.id == name }) { return .found(at) }
        if let at = shown.firstIndex(where: { $0.key == name }) { return .found(at) }
        if let at = shown.firstIndex(where: { !$0.version && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return .found(at) }
        return .none
    }

    /// A value an answer derives from text (a title, a preview, a place in words, a file's name): made from its
    /// source only after the source is redacted whole, never cut first (NoteTold).
    struct Derived {
        let make: ((String) -> String) -> Any
        init(_ make: @escaping ((String) -> String) -> Any) { self.make = make }
    }

    private static func clean(_ value: Any, _ index: UIMap.SecretIndex) -> Any {
        switch value {
        case let derived as Derived: return clean(derived.make { index.redacted($0) }, index)
        case let text as String: return index.redacted(text)
        case let list as [Any]: return list.map { clean($0, index) }
        case let map as [String: Any]: return map.mapValues { clean($0, index) }
        default: return value
        }
    }
}
