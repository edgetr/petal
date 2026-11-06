import AppKit
import Observation

/// Suggested modes and the weekly summary, as cards over the dock. The history is read off the main thread. At most
/// one suggestion a day, and never over another card or while a countdown runs.
@MainActor @Observable
final class InsightsController {
    @ObservationIgnored private var lastAnalysis = Date.distantPast
    @ObservationIgnored private var working = false

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    /// A card can go up: the dock is showing, and nothing else is over it.
    var cardFree: Bool {
        app.docks.shown && app.docks.focusedDock?.panel != nil && app.popups.card == nil && app.pendingMode == nil && !app.claude.isOpen
    }

    static var today: String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }

    /// Every minute the person is active.
    func tick(sinceLaunch: TimeInterval) {
        guard config.bool("activityLog"), !working else { return }
        if config.bool("summary") && weeklySummaryDue && cardFree {
            working = true
            let week = Self.weekKey
            Task {
                let summary = await Task.detached { Insights.summary(lastWeek: true) }.value
                working = false
                ActivityLog.setState("summaryWeek", week)
                if summary.total >= 30 && cardFree { app.popups.show(FocusCard(kind: .summary, summary: summary)) }
            }
            return
        }
        guard config.bool("suggestModes"), sinceLaunch > 600, Date().timeIntervalSince(lastAnalysis) > 3600,
              ActivityLog.state()["suggestionShown"] as? String != Self.today, cardFree else { return }
        lastAnalysis = Date()
        showSuggestion()
    }

    /// The first time the person is active after 9:00 on Monday, once a week.
    private var weeklySummaryDue: Bool {
        let monday = Insights.weekStart(Date())
        return Date() >= monday.addingTimeInterval(9 * 3600) && ActivityLog.state()["summaryWeek"] as? String != Self.weekKey
    }

    private static var weekKey: String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Insights.weekStart(Date()))
    }

    /// Looks at the history and shows the best suggestion, if there is one.
    func showSuggestion(marking: Bool = true) {
        guard !working else { return }
        working = true
        Task {
            let found = await Task.detached { Insights.suggestions().first }.value
            working = false
            guard let found, cardFree else { return }
            if marking { ActivityLog.setState("suggestionShown", Self.today) }
            app.popups.show(FocusCard(kind: .suggestion, desktop: app.docks.focusedDock?.desktop, suggestion: found))
        }
    }

    /// The last 7 days, now.
    func showSummary() {
        Task {
            let summary = await Task.detached { Insights.summary(lastWeek: false) }.value
            app.popups.show(FocusCard(kind: .summary, summary: summary))
        }
    }

    // MARK: Answers

    /// "Not now": not suggested again.
    func decline(_ card: FocusCard) {
        if let key = card.suggestion?.key { Insights.dismiss(key) }
        app.popups.dismissCard()
    }

    /// "Keep it" adds the app to the mode; "Make it" makes the mode, named by the AI when there is one.
    func accept(_ card: FocusCard) {
        guard let suggestion = card.suggestion else { return }
        if suggestion.kind == .add {
            accept(suggestion) { _ in }
            app.popups.dismissCard()
            return
        }
        var busy = card
        busy.working = true
        app.popups.show(busy)
        accept(suggestion) { [weak self] mode in
            guard let self, let mode, app.popups.card?.id == card.id else { return }   // closed while the AI was thinking
            app.popups.dismissCard()
            app.popups.show(FocusCard(kind: .made, target: mode, desktop: card.desktop, suggestion: suggestion))
        }
    }

    /// Does what a suggestion says: keeps the app in its mode, or makes the new mode (handing it back).
    func accept(_ suggestion: Insights.Suggestion, done: @escaping (Mode?) -> Void) {
        if suggestion.kind == .add {
            if let id = suggestion.apps.first { config.addApp(id, to: suggestion.mode) }
            return done(nil)
        }
        let names = suggestion.apps.map(Apps.name)
        if app.focus.brain.enabled {
            app.focus.brain.nameMode(apps: names) { [weak self] answer in done(self?.make(suggestion, answer)) }
        } else {
            done(make(suggestion, nil))
        }
    }

    private func make(_ suggestion: Insights.Suggestion, _ answer: [String: Any]?) -> Mode {
        let guess = suggestion.guess
        var name = (answer?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || name.count > 24 { name = guess?.name ?? "New mode" }
        var icon = answer?["icon"] as? String ?? ""
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil { icon = guess?.icon ?? "circle.fill" }
        let used = Set(config.modes.map { $0.hex.lowercased() })
        let color = NSColor(hex: answer?["color"] as? String)
            ?? Insights.palette.first { !used.contains($0) }.flatMap { NSColor(hex: $0) } ?? NSColor(hex: "#5fb8ff")!
        let about = (answer?["about"] as? String) ?? Insights.list(suggestion.apps.map(Apps.name))
        let mode = Mode(id: Self.uniqueID(name, taken: Set(config.modes.map(\.id))), name: name, icon: icon, color: color, about: about,
                        apps: suggestion.apps, sites: [], focusDelay: 0, allow: [])
        config.save(mode)
        return mode
    }

    /// "Design" → "design", "design-2" if that's taken.
    static func uniqueID(_ name: String, taken: Set<String>) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let base = slug.isEmpty ? "mode" : slug
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}
