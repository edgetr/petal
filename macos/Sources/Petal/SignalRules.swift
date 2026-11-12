import Foundation

/// What apps signal to the dock, as rules without AppKit (checked by checks/SignalRulesCheck.swift): which badges went
/// up, so the dock bounces those apps once, and which player's song the dock shows.
enum SignalRules {
    /// A badge as an amount: a number is itself ("12", and "99+" is 99, in any script's digits), a mark with no number
    /// in it ("•", "!") is less than one, and no badge is none. So "•" becoming "1" went up, and "99+" becoming "2" didn't.
    static func amount(_ label: String) -> Double {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        let digits = text.prefix { $0.wholeNumberValue != nil }
        guard !digits.isEmpty else { return 0.5 }
        return Double(digits.reduce(0) { min($0 * 10 + ($1.wholeNumberValue ?? 0), 1_000_000) })
    }

    /// One read of macOS's Dock's badges (bundle id → label), and which Dock answered (its process id) and when.
    struct Read: Equatable, Sendable {
        var dock: Int32
        var at: Date
        var badges: [String: String]
    }

    /// How long a Dock that has just started is given to show the badges apps already had: they come back one by one
    /// as apps register again, which isn't news.
    static let settle: TimeInterval = 10

    /// The apps whose badge went up from one read to the next, in order. None on the first read (what's there when
    /// Petal starts isn't news), none from a Dock other than the one read before or one that started under `settle`
    /// seconds ago (`dockSince`: when Petal first heard from it), and none for an app whose badge went down or went.
    static func wentUp(before: Read?, now: Read, dockSince: Date) -> [String] {
        guard let before, before.dock == now.dock, now.at.timeIntervalSince(dockSince) >= settle else { return [] }
        return now.badges.keys.sorted().filter { amount(now.badges[$0] ?? "") > amount(before.badges[$0] ?? "") }
    }

    /// Which of the players that have a song the dock shows, from whether each is playing (in the order they were
    /// asked): the first one playing, else the first one paused. None when none has a song.
    static func shownPlayer(playing: [Bool]) -> Int? {
        playing.firstIndex(of: true) ?? (playing.isEmpty ? nil : 0)
    }
}
