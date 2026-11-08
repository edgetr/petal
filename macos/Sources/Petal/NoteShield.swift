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

    /// The note an agent names (`rows`: each note's id, file path and title, and whether it's a version): its id, its
    /// path or its title, each compared as the agent may see it (redacted), never the raw text, so naming a guess
    /// can't tell whether a secret is in a title or file name.
    static func find(_ name: String, rows: [(id: String, key: String, title: String, version: Bool)], index: UIMap.SecretIndex) -> Lookup {
        guard !index.unreadable else { return .unreadable }
        let shown = rows.map { (id: index.redacted($0.id), key: index.redacted($0.key), title: index.redacted($0.title), version: $0.version) }
        if let at = shown.firstIndex(where: { !$0.version && $0.id == name }) { return .found(at) }
        if let at = shown.firstIndex(where: { $0.key == name }) { return .found(at) }
        if let at = shown.firstIndex(where: { !$0.version && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return .found(at) }
        return .none
    }

    private static func clean(_ value: Any, _ index: UIMap.SecretIndex) -> Any {
        switch value {
        case let text as String: return index.redacted(text)
        case let list as [Any]: return list.map { clean($0, index) }
        case let map as [String: Any]: return map.mapValues { clean($0, index) }
        default: return value
        }
    }
}
