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

    /// After a background act, read right before anything is put back: the note's app (`note`) in front now, and
    /// when the person last pressed a key, clicked or scrolled (uptime). Only an app that jumped forward with no
    /// input from the person since the baseline is undone, and only back to what was in front then.
    static func restore(_ baseline: Baseline, note: pid_t, noteFrontNow: Bool, lastInput: TimeInterval) -> Restore {
        guard noteFrontNow, lastInput < baseline.at, let before = baseline.front else { return .none }
        return before == note ? .window : .app(before)
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
