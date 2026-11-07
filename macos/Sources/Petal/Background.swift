import Foundation

/// A sticky note works in its own window in the background (ComputerUse.swift): it presses, types and scrolls there
/// through Accessibility alone, while the person works elsewhere, and nothing comes forward. These are its pure
/// decisions, checked by macos/checks/run.sh: which way an act goes, what it does in the background for each kind of
/// action, what needs the window in front, and what each note's line says in the AI button's preview.
enum Background {
    /// What the person and the note's app are doing, read right before an act.
    struct Situation: Equatable {
        /// The caller is a sticky note acting on the window (or tab) it's stuck to: never Petal AI's plain chat or an
        /// AI session outside Petal, which keep the pink pointer.
        var note: Bool
        /// The note's app is the one in front.
        var appFront: Bool
        /// The note's window is its app's focused window.
        var windowFocused: Bool
        /// Seconds since the person last pressed a key, clicked or scrolled.
        var idle: TimeInterval
    }

    enum Way: Equatable {
        /// As Petal AI always does: its pink pointer, the window brought forward when keys need it.
        case foreground
        /// Quietly: Accessibility only, nothing comes forward, the person's pointer and keyboard untouched.
        case background
        /// The person is working in that very window right now: wait for a pause.
        case wait
    }

    /// A pause this long in the note's window, in front, means the person isn't typing there.
    static let pause: TimeInterval = 2
    /// How long an act waits for that pause before it gives up.
    static let patience: TimeInterval = 8

    static func way(_ situation: Situation) -> Way {
        guard situation.note else { return .foreground }
        // The note's own window is the one the person has in front: they can see it, so it's done there, as always,
        // but never while they're typing or clicking in it.
        if situation.appFront && situation.windowFocused { return typingThere(situation) ? .wait : .foreground }
        return .background
    }

    /// Right before a change it was going to make with the pointer (the note's window was in front when it
    /// decided), read again: the window still in front and the person idle goes ahead; the person gone elsewhere
    /// meanwhile sends it the background way (which never brings anything forward, and says what needs the window);
    /// the person now typing there refuses it.
    enum Recheck: Equatable { case go, background, refuse }

    static func recheck(_ situation: Situation) -> Recheck {
        switch way(situation) {
        case .foreground: .go
        case .background: .background
        case .wait: .refuse
        }
    }

    /// Right before each change it makes in the background, read again: the person may have come back to that
    /// window (or its app) during the reads since it decided. Only `go` changes anything.
    enum Behind: Equatable {
        /// Still the background way, as planned.
        case go
        /// Nothing changed yet: decide again (the foreground rules, with their pause, if the window is in front now).
        case again
        /// Something already changed: stop there, never the person's window.
        case stop
    }

    /// `plannedFront`: its app was in front when the background step was planned (keys and focus are planned only for
    /// an app behind). `changed`: an earlier change of this act was already made.
    static func behind(_ situation: Situation, plannedFront: Bool, changed: Bool) -> Behind {
        let still = way(situation) == .background && (plannedFront || !situation.appFront)
        if still { return .go }
        return changed ? .stop : .again
    }

    /// The person is working in the note's window right now: it's in front and they pressed a key, clicked or
    /// scrolled within the last two seconds.
    static func typingThere(_ situation: Situation) -> Bool {
        situation.appFront && situation.windowFocused && situation.idle < pause
    }

    // MARK: A note typing in its window in front

    /// What ends a note's typing in its window in front (it went ahead because the person was idle there), read
    /// again before every batch of keys, a focus change and Return: the person typing or clicking there again
    /// (`typing`), or that window no longer the one in front (`left`). Nil: carry on. Petal AI's plain chat never
    /// asks (it has its guard and Escape).
    enum Interrupt: Equatable { case typing, left }

    static func interrupt(_ situation: Situation) -> Interrupt? {
        switch way(situation) {
        case .foreground: nil
        case .wait: .typing
        case .background: .left
        }
    }

    /// What the AI is told when its typing was interrupted: how much of `text` went (`typed`, its start), and that
    /// Return wasn't pressed.
    static func interrupted(_ why: Interrupt, app: String, typed: String, of text: String) -> String {
        let who = why == .typing ? "The person started typing in \(app)'s window" : "The person moved away from \(app)'s window"
        let what: String
        if typed.isEmpty { what = "before typing anything" }
        else if typed == text { what = "after typing all of it, and Return wasn't pressed" }
        else { what = "part way: only “\(typed)” of “\(text)” was typed, and Return wasn't pressed" }
        return "\(who), so Petal stopped \(what). Don't type it again: wait until they're done, then petal_ui to see what the field holds now."
    }

    /// The same for any other act (a press, focus, scroll, menu or key): `changed`, something of it was already done.
    static func stopped(_ why: Interrupt, app: String, changed: Bool) -> String {
        switch (why, changed) {
        case (.typing, false): return busyThere(app)
        case (.typing, true): return "The person started typing in \(app)'s window, so Petal stopped part way. Don't do it again: wait until they're done, then petal_ui to see what was done."
        case (.left, false): return "The person moved away from \(app)'s window, so nothing was done there. Call petal_ui and try again."
        case (.left, true): return "The person moved away from \(app)'s window, so Petal stopped part way. Call petal_ui to see what was done."
        }
    }

    /// The person is typing in that window: nothing was done.
    static func busyThere(_ app: String) -> String {
        "The person is typing in \(app)'s window right now, so nothing was done there. Wait a little, then petal_ui and try again."
    }

    /// A vault fill interrupted the same way: never what went in (it's a secret), only whether any of it did, and
    /// never Return after it.
    static func fillInterrupted(_ why: Interrupt, app: String, typed: Bool) -> String {
        let who = why == .typing ? "The person started typing in \(app)'s window" : "The person moved away from \(app)'s window"
        let what = typed ? "part way: what went in may need clearing, and Return wasn't pressed" : "before filling anything"
        return "\(who), so Petal stopped \(what). Don't fill it again until they're done; then petal_ui to see the field."
    }

    // MARK: Guard, then change

    /// What a guard says right before a change.
    enum Verdict: Equatable {
        case go
        /// Stopped (Stop, steering, a new turn), or the background way no longer holds: its own reason is kept by the caller.
        case no
        /// A note acting in its window in front: the person typing there again, or gone elsewhere.
        case interrupted(Interrupt)
    }

    /// A note's guard in its window in front (and every caller's Stop): `note` is the situation read just now for a
    /// note, nil for anyone else.
    static func verdict(stopped: Bool, note: Situation?) -> Verdict {
        if stopped { return .no }
        if let note, let why = interrupt(note) { return .interrupted(why) }
        return .go
    }

    /// Every change on a note's path (a value set, focus, select-all, each batch of keys, Return, a press, a scroll, a
    /// menu item) goes through `mutate`: its guard runs, then the change at once, with nothing read in between. The
    /// reads a change needs (where the keyboard is, the page, the window) come before `mutate`, never inside it
    /// ahead of the change. One gate per act: it remembers whether it ever let a change through and why it last
    /// refused.
    final class Gate {
        private let check: () -> Verdict
        /// It let a change through: something of the act was done.
        private(set) var changed = false
        /// It refused a change (stopped, or interrupted).
        private(set) var refused = false
        /// Why it refused, when the person interrupted.
        private(set) var interruption: Interrupt?

        init(_ check: @escaping () -> Verdict) { self.check = check }

        /// The guard, then `change` immediately. Nil, with nothing changed, when the guard says no.
        @discardableResult
        func mutate<T>(_ change: () -> T) -> T? {
            switch check() {
            case .go:
                changed = true
                return change()
            case .no:
                refused = true
            case .interrupted(let why):
                refused = true
                interruption = why
            }
            return nil
        }
    }

    /// Sends `chunks` in order (batches of keys). Before each: the reads (`still`: the keyboard still in the field,
    /// the page still the one), then the gate and the chunk together. False when a read or the gate stopped it.
    static func send<Chunk>(_ chunks: [Chunk], still: () -> Bool, gate: Gate, post: (Chunk) -> Void) -> Bool {
        for chunk in chunks {
            guard still() else { return false }
            guard gate.mutate({ post(chunk) }) != nil else { return false }
        }
        return true
    }

    // MARK: Each action in the background

    /// What can't be done in the background, so the window must come forward (the person brings it).
    enum Reason: String, Equatable, CaseIterable {
        /// A menu acts on its app's front window: another of its windows, or the app the person is using.
        case menu
        /// Keys go to the app's focused window, which is the person's while they use that app.
        case keys
        /// Moving the cursor in the app the person is using would move theirs.
        case focus
        /// Copying and pasting use the person's clipboard.
        case clipboard
        /// The vault fills only with its window in front.
        case vault
        /// The app didn't take the keys while it was in the background.
        case ignored
        /// The text didn't stay in the field.
        case didntStick
        /// A tab's note acts only while its tab is the one showing.
        case tab
        /// It opens something in another app (a link, a file), which would come to the front.
        case opens

        /// For the note's line: "Waiting for you: <status>".
        var status: String {
            switch self {
            case .menu: "needs the window in front to choose from its menus"
            case .keys: "needs the window in front to press keys"
            case .focus: "needs the window in front to move its cursor"
            case .clipboard: "needs the window in front to copy or paste"
            case .vault: "needs the window in front to fill from your vault"
            case .ignored: "needs the window in front: the app ignores typing in the background"
            case .didntStick: "needs the window in front: the text didn't stay in the field"
            case .tab: "needs its tab showing"
            case .opens: "needs the window in front: that opens another app"
            }
        }

        /// What the AI is told.
        func words(_ app: String) -> String {
            let why: String
            switch self {
            case .menu: why = "Choosing from \(app)'s menus needs that window in front."
            case .keys: why = "Pressing keys there needs that window in front (keys go to the window the person is using)."
            case .focus: why = "Moving the cursor there needs that window in front while the person uses \(app)."
            case .clipboard: why = "Copying and pasting use the person's clipboard, so they need that window in front."
            case .vault: why = "Filling from the vault needs that window in front."
            case .ignored: why = "\(app) ignored the typing while it was in the background."
            case .didntStick: why = "The text didn't stay in that field in the background."
            case .opens: why = "That opens something in another app (a link or a file), which would come to the front over what the person is using."
            case .tab:
                return "This note's tab isn't the one showing in its window, and a browser doesn't let anything use a tab in the background. Nothing was done. Ask the person to show that tab (clicking this note in the AI button's preview does), then petal_ui again."
            }
            return why + " Nothing was done, and Petal didn't bring it forward, so as not to interrupt the person. Say in one line what you need and ask them to bring the window forward (clicking this note in the AI button's preview does it); once it's in front, petal_ui again and carry on."
        }
    }

    /// The act, as Petal's Accessibility sees it.
    struct Target: Equatable {
        var action: String
        /// A text field or area.
        var text = false
        /// In a web page (a browser's, or an Electron app's such as T3 Code, Slack or VS Code).
        var web = false
        /// It copies or pastes (a key, a menu item or a button).
        var clipboard = false
        /// A key its app's menus have (chosen there instead).
        var menuItem = false
        /// A control was named (a key goes to it first).
        var element = false
        /// The note's app is the one in front.
        var appFront = false
        /// The note's window is its app's focused window.
        var windowMain = false
    }

    enum Step: Equatable {
        /// AXPress, AXPick, AXConfirm or AXOpen, or selecting a row, cell or tab.
        case press
        /// AXScrollToVisible, or the scroll bar's value.
        case scroll
        /// The control takes its app's keyboard focus, inside that app only.
        case focus
        /// The field's value, read back; keys after it if it didn't stick and keys may go.
        case setValue(keysAfter: Bool)
        /// The control takes its app's focus, then the text goes as keys posted to that app's process alone.
        case keys
        /// The app's menu item, through Accessibility (a menu, or a key its menus have).
        case menu
        /// One key, posted to that app's process alone.
        case key
        /// Can't be done in the background.
        case needs(Reason)
    }

    /// A button that copies or pastes (by its app's own name for it, or any copy or paste word in its names:
    /// "Quick paste", "Click to copy API key") uses the person's clipboard: in the background it needs the window.
    static func pressUsesClipboard(_ nodes: [UINode]) -> Bool {
        nodes.contains { UIMap.clip(control: $0) != nil || UIMap.mightCopy($0) || UIMap.mightPaste($0) }
    }

    /// What a note does in the background for each action. Keys and focus only while its app isn't the one in front:
    /// keys go to an app's focused window, and focus moves its cursor, so in the app the person is using they'd
    /// reach the person's window. A web page's field hears keys (its page reacts to them), a native one takes its
    /// value. Nothing that uses the clipboard, and no vault fill.
    static func plan(_ target: Target) -> Step {
        let keysGo = !target.appFront
        switch target.action {
        case "fill": return .needs(.vault)
        case "press": return target.clipboard ? .needs(.clipboard) : .press
        case "scroll": return .scroll
        case "focus": return keysGo ? .focus : .needs(.focus)
        case "type":
            guard target.text else { return keysGo ? .keys : .needs(.keys) }
            if target.web { return keysGo ? .keys : .setValue(keysAfter: false) }
            return .setValue(keysAfter: keysGo)
        case "menu":
            if target.clipboard { return .needs(.clipboard) }
            return keysGo && target.windowMain ? .menu : .needs(.menu)
        case "key":
            if target.clipboard { return .needs(.clipboard) }
            guard keysGo else { return .needs(.keys) }
            if target.menuItem { return target.windowMain ? .menu : .needs(.menu) }
            // With no control named, the key goes to the app's focused window: only when that's the note's.
            return target.element || target.windowMain ? .key : .needs(.keys)
        default: return .needs(.keys)
        }
    }

    /// What a press may do in the background: AXPress, AXPick or AXConfirm, never AXOpen (it opens a file or an item
    /// in another app). Nil: none of them.
    static func pressAction(_ actions: [String]) -> String? {
        ["AXPress", "AXPick", "AXConfirm"].first(where: actions.contains)
    }

    /// A press that would open something in another app, which comes to the front over the person's: a link, unless
    /// it's a web address in a browser (it opens there); anything with an address that isn't a web one (a file in
    /// Finder, mailto:, an app's own scheme); a web address outside a browser (the default browser comes forward).
    static func pressOpens(role: String, url: String?, browser: Bool) -> Bool {
        let address = url?.trimmingCharacters(in: .whitespaces) ?? ""
        guard role == "AXLink" || !address.isEmpty else { return false }
        let scheme = URL(string: address)?.scheme?.lowercased()
        return !(browser && (scheme == "http" || scheme == "https"))
    }

    /// Typed in the background, read back: `done` only when the field says exactly what was asked; `ignored` when
    /// nothing changed (the app ignored the keys); anything else is `uncertain`, never counted as done.
    enum Typed: Equatable { case done, ignored, uncertain }

    /// `replace`: the field's whole value must be the text (spaces at the ends aside). Else the text goes in at the
    /// cursor, `at` (its UTF-16 offset, when the field said) over `replaced` selected units: the value must have
    /// changed by exactly that, with the text there (anywhere, when the cursor wasn't known).
    static func typed(before: String, after: String, text: String, replace: Bool, at: Int? = nil, replaced: Int = 0) -> Typed {
        let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if replace {
            if trim(after) == trim(text) { return .done }
            return after == before ? .ignored : .uncertain
        }
        if after == before { return text.isEmpty ? .done : .ignored }
        let now = Array(after.utf16), was = Array(before.utf16), new = Array(text.utf16)
        guard now.count == was.count - replaced + new.count else { return .uncertain }
        if let at {
            guard at >= 0, at + new.count <= now.count, at <= was.count else { return .uncertain }
            let fits = Array(now[at..<(at + new.count)]) == new && Array(now[..<at]) == Array(was[..<at])
            return fits ? .done : .uncertain
        }
        return replaced == 0 && after.contains(text) ? .done : .uncertain
    }

    /// Return after typing goes only where keys may.
    static func returnGoes(appFront: Bool) -> Bool { !appFront }

    /// The app in front and the time, taken together before a background act is prepared: what's given back after
    /// it, and since when the person's own keys and clicks count.
    struct Baseline: Equatable {
        /// The app in front (its process).
        var front: pid_t?
        /// The system's uptime then.
        var at: TimeInterval
    }

    enum Restore: Equatable {
        /// Leave it: nothing jumped forward, or the person did something since (then it's theirs to decide).
        case none
        /// The note's app jumped to the front by itself: the person's app (this process) goes back in front.
        case app(pid_t)
        /// The person was using the note's app: their own window goes back over the note's, if the act raised it.
        case window
    }

    /// After a background act, read right before anything is put back: the app in front now (`frontNow`: the
    /// note's, or any other a press opened, such as Safari for a link), and when the person last pressed a key,
    /// clicked or scrolled (uptime). Only an app that came forward with no input from the person since the baseline
    /// is undone, and only back to what was in front then; the note's app still in front, as it was, may have raised
    /// the note's window over the person's.
    static func restore(_ baseline: Baseline, note: pid_t, frontNow: pid_t?, lastInput: TimeInterval) -> Restore {
        guard let now = frontNow, lastInput < baseline.at, let before = baseline.front else { return .none }
        if now == before { return before == note ? .window : .none }
        return .app(before)
    }

    /// Something came forward in another app than the note's and the person's (a link opened in a browser, a file in
    /// its app), with no input from the person since the baseline: the AI is told, whether or not it was put back.
    static func opened(_ baseline: Baseline, note: pid_t, frontNow: pid_t?, lastInput: TimeInterval) -> Bool {
        guard let now = frontNow, lastInput < baseline.at else { return false }
        return now != note && now != baseline.front
    }
}

/// The AI button's preview of a note's window: never a private app's (whether or not its window is still there),
/// and never a stale one.
enum NotePicture {
    /// A note as the preview sees it.
    struct Seen: Equatable {
        /// Its app's bundle id ("" for none).
        var app: String
        /// Stuck to a window that's still there.
        var attached: Bool
        var pid: pid_t
        var window: UInt32?
        /// Its app is kept private.
        var hidden: Bool
        /// Stuck to all of its app, not one window: any of that app's ordinary windows may stand for it.
        var appWide = false
    }

    /// The window ScreenCaptureKit gave back for a picture.
    struct Shot: Equatable {
        var pid: pid_t
        var window: UInt32
    }

    /// Which window a picture may be of. A note stuck to one window: that very window, by its number and process,
    /// or none. A note on all of an app: the window it names, else (that one gone, or none named) any window of its
    /// app. Nil: no picture.
    static func pick(_ seen: Seen, from windows: [Shot], ordinary: (Shot) -> Bool = { _ in true }) -> Shot? {
        guard shows(seen) else { return nil }
        if let wanted = seen.window, let exact = windows.first(where: { $0.window == wanted && $0.pid == seen.pid }) { return exact }
        guard seen.appWide else { return nil }
        return windows.first { $0.pid == seen.pid && ordinary($0) }
    }

    /// A picture is kept only when the window it shows is one `pick` allows for the note as it was asked for, and
    /// the note, read again once it's done, still shows one of the very same window (`keeps`).
    static func accepts(_ shot: Shot, taken: Seen, now: Seen?) -> Bool {
        guard keeps(taken: taken, now: now), shot.pid == taken.pid else { return false }
        if let wanted = taken.window, shot.window == wanted { return true }
        return taken.appWide
    }

    /// Kept private by its app, even once its window closed or its app quit: the app it was stuck to decides.
    static func hidden(app: String?, private isPrivate: (String) -> Bool) -> Bool {
        guard let app, !app.isEmpty else { return false }
        return isPrivate(app)
    }

    /// A picture kept for a note, with the note as it was when the picture was taken: shown only while the note
    /// still has that very window (`current`), never an older window's after it moved.
    struct Kept<Image> {
        var seen: Seen
        var image: Image
    }

    /// The kept picture to show for the note as it is now, if it's still of the note's window.
    static func current<Image>(_ kept: Kept<Image>?, now: Seen) -> Image? {
        guard let kept, keeps(taken: kept.seen, now: now) else { return nil }
        return kept.image
    }

    /// A picture shows (and is kept) only for a note stuck to a window still there, of an app not kept private.
    static func shows(_ seen: Seen) -> Bool { seen.attached && !seen.hidden }

    /// A picture taken of `taken` is kept only if the note, read again once it's done, still shows one, of the
    /// very same window of the same app.
    static func keeps(taken: Seen, now: Seen?) -> Bool {
        guard let now, shows(now), shows(taken) else { return false }
        return now.app == taken.app && now.pid == taken.pid && now.window == taken.window && now.appWide == taken.appWide
    }
}

/// Each note's line in the AI button's preview and on the note: what it's doing, done, or waiting for the person.
enum NoteStatus {
    struct Facts: Equatable {
        var running = false
        /// Done while the person was elsewhere, not seen yet.
        var ready = false
        /// Its Allow card is waiting (its title).
        var asking: String?
        /// What it needs the person for (Background.Reason.status).
        var needs: String?
        /// Its latest step, in plain words.
        var activity = ""
    }

    /// The preview shows this many tiles side by side; more scroll sideways, none left out.
    static let tilesInView = 4
    static func previewScrolls(_ count: Int) -> Bool { count > tilesInView }

    /// Shown in the preview: working (or queued for room: `running`), waiting for the person, or done and not seen.
    static func shows(_ facts: Facts) -> Bool { facts.running || facts.ready || needsYou(facts) }

    /// Waiting for the person: the AI button gets a small ✦.
    static func needsYou(_ facts: Facts) -> Bool { facts.asking != nil || facts.needs != nil }

    static func line(_ facts: Facts) -> String {
        if let asking = facts.asking { return "Waiting for you: " + asking }
        if let needs = facts.needs { return "Waiting for you: " + needs }
        if facts.running { return step(facts.activity) }
        return facts.ready ? "Done" : ""
    }

    /// A step as one short line: "Running  git status" → "Running git status…".
    static func step(_ activity: String) -> String {
        let words = activity.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return "Working…" }
        let short = words.count > 60 ? String(words.prefix(59)) + "…" : words
        return short.hasSuffix("…") || short.hasSuffix(".") ? short : short + "…"
    }

    /// The order they show in: waiting for the person first, then working, then done; otherwise as they were.
    static func order(_ facts: [Facts]) -> [Int] {
        let rank = { (facts: Facts) -> Int in needsYou(facts) ? 0 : facts.running ? 1 : 2 }
        return facts.indices.filter { shows(facts[$0]) }.sorted { (rank(facts[$0]), $0) < (rank(facts[$1]), $1) }
    }
}
