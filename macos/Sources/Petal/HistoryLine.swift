import Foundation

/// A line of "What Petal AI did" (Settings › AI, kept in ai-history.json) before it's kept. Its words are Petal's
/// own, written here as a literal; whatever it names (an app, a window's title, a file, a site, a memory's words, a
/// vault item's title, what an agent said it was doing) can only go in as a name, with what to say in its place when
/// it must be left out. Every name is put through the vault's settled redaction before the line is kept, and left
/// out while the vault can't be read (`text`). A plain string is not a line: `Assist.did` takes nothing else, so no
/// name reaches the history any other way (macos/checks/run.sh checks that a raw string doesn't compile).
struct HistoryLine: ExpressibleByStringInterpolation, Sendable, Equatable {
    enum Part: Sendable, Equatable {
        /// Petal's own words.
        case words(String)
        /// Something named: redacted whole, or `missing` in its place. `quoted`: shown in “ ”.
        case name(String, missing: String, quoted: Bool)
    }

    private(set) var parts: [Part]

    init(stringLiteral value: String) { parts = [.words(value)] }
    init(stringInterpolation: Interpolation) { parts = stringInterpolation.parts }

    struct Interpolation: StringInterpolationProtocol {
        var parts: [Part] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { if !literal.isEmpty { parts.append(.words(literal)) } }
        /// Something named, as it is: "Quit \(named: app, else: "an app")".
        mutating func appendInterpolation(named name: String, else missing: String) { parts.append(.name(name, missing: missing, quoted: false)) }
        /// Something named, in quotes: "Closed \(quoted: title, else: "a window")".
        mutating func appendInterpolation(quoted name: String, else missing: String) { parts.append(.name(name, missing: missing, quoted: true)) }
        /// A count.
        mutating func appendInterpolation(_ number: Int) { parts.append(.words(String(number))) }
        /// Another line, with its own names.
        mutating func appendInterpolation(_ line: HistoryLine) { parts += line.parts }
    }

    /// Whether it names anything (else it's Petal's own words, kept as they are).
    var hasNames: Bool { parts.contains { if case .name = $0 { true } else { false } } }

    /// The line as it's kept: every name through `redact`; nil (the vault can't be read), every name left out, what
    /// to say instead in its place.
    func text(_ redact: ((String) -> String)?) -> String {
        parts.map { part in
            switch part {
            case .words(let words): return words
            case .name(let name, let missing, let quoted):
                guard let redact, !name.isEmpty else { return missing }
                return quoted ? "“" + redact(name) + "”" : redact(name)
            }
        }.joined()
    }
}
