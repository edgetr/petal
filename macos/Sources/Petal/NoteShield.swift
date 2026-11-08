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

    /// `ambiguous`: the name is the title of more than one note as the tools tell it (the papers' places): none is
    /// picked; the agent is told their handles.
    enum Lookup: Equatable { case found(Int), none, unreadable, ambiguous([Int]) }

    /// The note an agent names (`rows`: each paper's handle, its text, and whether it's a version): its handle (a
    /// random token, a conflict's copy its own), or its title as the tools tell it (derived after redaction), never
    /// the raw text, a file name or a path.
    static func find(_ name: String, rows: [(handle: String, body: String, version: Bool)], index: UIMap.SecretIndex) -> Lookup {
        guard !index.unreadable else { return .unreadable }
        if let at = rows.firstIndex(where: { $0.handle == name }) { return .found(at) }
        // A conflict's copy named by its handle after the conflict was settled: the note's one paper now.
        if let dot = name.firstIndex(of: ".") {
            let base = String(name[..<dot])
            let papers = rows.indices.filter { rows[$0].handle == base }
            if papers.count == 1 { return .found(papers[0]) }
        }
        // By title only when exactly one note has it as the tools tell it (redaction can make two alike).
        let redact = { (text: String) in index.redacted(text) }
        let titled = rows.indices.filter { !rows[$0].version && NoteTold.title(rows[$0].body, redact).localizedCaseInsensitiveCompare(name) == .orderedSame }
        if titled.count == 1 { return .found(titled[0]) }
        if titled.count > 1 { return .ambiguous(titled) }
        return .none
    }

    /// A note as the tools tell it: its handle (never a file name, path or an id taken from one), its title and
    /// preview derived after redaction, its notebook, its places in words (cut only after redaction; a private app's
    /// already scrubbed), and with `text` its whole text with every picture as `![picture N]`.
    static func note(handle: String, body: String, notebook: String, places: [NoteStick], modified: String, onScreen: Bool,
                     text: Bool = false, created: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["id": handle, "title": Derived { NoteTold.title(body, $0) }, "notebook": notebook,
                                  "preview": Derived { NoteTold.preview(body, $0) },
                                  "places": places.map { place in Derived { place.redacted($0).words } },
                                  "modified": modified, "onScreen": onScreen]
        if text { out["text"] = NoteTold.neutralPictures(body) }
        if let created { out["created"] = created }
        return out
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
