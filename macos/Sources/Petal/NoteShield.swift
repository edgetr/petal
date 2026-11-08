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

    private static func clean(_ value: Any, _ index: UIMap.SecretIndex) -> Any {
        switch value {
        case let text as String: return index.redacted(text)
        case let list as [Any]: return list.map { clean($0, index) }
        case let map as [String: Any]: return map.mapValues { clean($0, index) }
        default: return value
        }
    }
}
