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
        /// The window is on the run's own hidden display (RunDisplay.swift): the person can't see it, so it's never
        /// worked on with the pointer, whatever is in front.
        var hidden = false
    }

    /// A fact read through Accessibility: an error or a timeout is `unknown`, never taken for `no`.
    enum Known: Equatable { case yes, no, unknown }

    /// A note's situation from what was read: `appFront`, then (only when it's in front) whether the note's window is
    /// its focused one. Nil when either couldn't be told: then nothing changes there (`unsure`), never assumed behind.
    static func situation(appFront: Known, windowFocused: Known, idle: TimeInterval, hidden: Bool = false) -> Situation? {
        switch appFront {
        case .unknown: return nil
        case .no: return Situation(note: true, appFront: false, windowFocused: false, idle: idle, hidden: hidden)
        case .yes:
            guard windowFocused != .unknown else { return nil }
            return Situation(note: true, appFront: true, windowFocused: windowFocused == .yes, idle: idle, hidden: hidden)
        }
    }

    /// What the AI is told when Petal couldn't tell whether the person is using the note's window.
    static func unsure(_ app: String, changed: Bool) -> String {
        "Petal couldn't tell whether the person is using \(app)'s window (it didn't answer in time), so "
            + (changed ? "it stopped part way. Call petal_ui to see what was done." : "nothing was done there. Call petal_ui and try again.")
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
        // On the run's own display nobody is looking: always the background way, never the pointer, never a wait.
        if situation.hidden { return .background }
        // The note's own window is the one the person has in front: they can see it, so it's done there, as always,
        // but never while they're typing or clicking in it.
        if situation.appFront && situation.windowFocused { return typingThere(situation) ? .wait : .foreground }
        return .background
    }

    /// Right before a change it was going to make with the pointer (the note's window was in front when it
    /// decided), read again: the window still in front and the person idle goes ahead; the person gone elsewhere
    /// meanwhile sends it the background way (which never brings anything forward, and says what needs the window);
    /// the person now typing there refuses it.
    /// `unsure`: it couldn't be told (an Accessibility read failed): refused.
    enum Recheck: Equatable { case go, background, refuse, unsure }

    static func recheck(_ situation: Situation?) -> Recheck {
        guard let situation else { return .unsure }
        switch way(situation) {
        case .foreground: return .go
        case .background: return .background
        case .wait: return .refuse
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
        /// Couldn't tell whether the person is there: nothing more changes.
        case unsure
    }

    /// `plannedFront`: its app was in front when the background step was planned (keys and focus are planned only for
    /// an app behind). `changed`: an earlier change of this act was already made.
    static func behind(_ situation: Situation, plannedFront: Bool, changed: Bool) -> Behind {
        let still = way(situation) == .background && (plannedFront || !situation.appFront)
        if still { return .go }
        return changed ? .stop : .again
    }

    // MARK: The person's own use of an app wins

    /// A run in its window on its own display needs something that reaches the app's window in front (real keys, the
    /// cursor, a menu), and the person is using that app: its keys would be theirs. The run waits for them to leave
    /// the app and says so ("Waiting for TextEdit"), then tries again; past `personPatience` it's told, as before.
    enum PersonFirst: Equatable {
        /// Wait for the person to leave the app.
        case wait
        /// They left: try the act again.
        case retry
        /// Tell the AI it can't be done now (`Reason.words`).
        case tell
    }

    /// How long a run waits for the person to leave an app before it's told to find another way.
    static let personPatience: TimeInterval = 120

    /// What needs the app out of the person's hands, and nothing else: keys, the cursor, a menu.
    static func waitsForPerson(_ reason: Reason) -> Bool { [.keys, .focus, .menu].contains(reason) }

    /// An act came back needing the window in front. `hidden`: its window is on the run's own display; `untouched`:
    /// nothing of the act was done yet; `appFront`: the person has that app in front (unknown: Petal couldn't tell);
    /// `waited`: how long this act has waited for them already.
    static func personFirst(_ reason: Reason, hidden: Bool, untouched: Bool, appFront: Known, waited: TimeInterval) -> PersonFirst {
        guard hidden, untouched, waitsForPerson(reason), appFront == .yes, waited < personPatience else { return .tell }
        return .wait
    }

    /// While it waits, asked again now and then: the app still in front, or gone from it.
    static func personStill(appFront: Bool, waited: TimeInterval) -> PersonFirst {
        if !appFront { return .retry }
        return waited < personPatience ? .wait : .tell
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
    /// `unsure`: Petal couldn't tell (an Accessibility read failed), so it stops as if they had come back.
    enum Interrupt: Equatable { case typing, left, unsure }

    /// Who stopped it, for what the AI is told.
    private static func who(_ why: Interrupt, _ app: String) -> String {
        switch why {
        case .typing: "The person started typing in \(app)'s window"
        case .left: "The person moved away from \(app)'s window"
        case .unsure: "Petal couldn't tell whether the person is using \(app)'s window"
        }
    }

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
        let who = who(why, app)
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
        case (.unsure, _): return unsure(app, changed: changed)
        }
    }

    /// The person is typing in that window: nothing was done.
    static func busyThere(_ app: String) -> String {
        "The person is typing in \(app)'s window right now, so nothing was done there. Wait a little, then petal_ui and try again."
    }

    /// A vault fill interrupted the same way: never what went in (it's a secret), only whether any of it did, and
    /// never Return after it.
    static func fillInterrupted(_ why: Interrupt, app: String, typed: Bool) -> String {
        let who = who(why, app)
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

    /// A gate's check in its order: a Stop already heard ends it with nothing read; else the reads (`read`: a note's
    /// situation through Accessibility, which can take a while; nil for anyone else), and only then the Stop sampled
    /// again, last, right before the verdict: a Stop, steering, a new turn or the app made private (all of which stop
    /// `cancel`) during those reads is heard.
    static func check(stopped: () -> Bool, read: () -> Situation?) -> Verdict {
        if stopped() { return .no }
        let note = read()
        let stoppedNow = stopped()
        return verdict(stopped: stoppedNow, note: note)
    }

    /// A note's check in its window in front: the same, but its situation unreadable (nil) is never taken for the
    /// person idle there or gone: it stops (`unsure`).
    static func check(stopped: () -> Bool, note read: () -> Situation?) -> Verdict {
        if stopped() { return .no }
        let note = read()
        if stopped() { return .no }
        guard let note else { return .interrupted(.unsure) }
        return verdict(stopped: false, note: note)
    }

    /// The same for a change made in the background: the situation read, then the Stop last. Nil: stopped. A
    /// situation that couldn't be read is `unsure`: never assumed behind.
    static func check(stopped: () -> Bool, read: () -> Situation?, plannedFront: Bool, changed: Bool) -> Behind? {
        if stopped() { return nil }
        let now = read()
        if stopped() { return nil }
        guard let now else { return .unsure }
        return behind(now, plannedFront: plannedFront, changed: changed)
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
            case .opens: "needs the window in front: that opens something"
            }
        }

        /// What the AI is told. `hidden`: the window is on the run's own display, where nothing can come forward: the
        /// person brings it to their screen with Show me.
        func words(_ app: String, hidden: Bool = false) -> String {
            if hidden { return onDisplay(app) }
            let why: String
            switch self {
            case .menu: why = "Choosing from \(app)'s menus needs that window in front."
            case .keys: why = "Pressing keys there needs that window in front (keys go to the window the person is using)."
            case .focus: why = "Moving the cursor there needs that window in front while the person uses \(app)."
            case .clipboard: why = "Copying and pasting use the person's clipboard, so they need that window in front."
            case .vault: why = "Filling from the vault needs that window in front."
            case .ignored: why = "\(app) ignored the typing while it was in the background."
            case .didntStick: why = "The text didn't stay in that field in the background."
            case .opens: why = "That opens something (a link, a file, a window, or another app), which would come to the front over what the person is using."
            case .tab:
                return "This note's tab isn't the one showing in its window, and a browser doesn't let anything use a tab in the background. Nothing was done. Ask the person to show that tab (clicking this note in the AI button's preview does), then petal_ui again."
            }
            return why + " Nothing was done, and Petal didn't bring it forward, so as not to interrupt the person. Say in one line what you need and ask them to bring the window forward (clicking this note in the AI button's preview does it); once it's in front, petal_ui again and carry on."
        }

        /// The same for a window on the run's own display: nothing there can come forward, so the ways out are another
        /// way of doing it, waiting until the person has left that app, or the person's own Show me.
        private func onDisplay(_ app: String) -> String {
            let why: String
            switch self {
            case .menu: why = "\(app)'s menus act on the window the person is using there (or its window in front), not on yours."
            case .keys: why = "Keys go to the window the person is using in \(app), not to yours."
            case .focus: why = "Moving the cursor there would move the person's own in \(app)."
            case .clipboard: why = "Copying and pasting use the person's clipboard."
            case .vault: why = "The vault fills only a window in front of the person."
            case .ignored: why = "\(app) ignored the typing in a window that isn't in front."
            case .didntStick: why = "The text didn't stay in that field."
            case .opens: why = "That opens something (a link, a file, a window, or another app), which could come up in front of the person."
            case .tab: why = "Its tab isn't the one showing in its window."
            }
            return why + " Nothing was done. This window is on your own display, where nothing comes forward. Try another way (type into the field itself, press a button instead of a key or a menu), or wait until the person isn't using \(app); if it can only be done in front of them, say in one line what you need and ask them to press Show me (on this run in the AI button's preview), which brings the window to their screen, then petal_ui again."
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
        /// A menu item or key that opens something (`menuOpens`, `keyOpens`).
        var opens = false
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
            if target.opens { return .needs(.opens) }
            return keysGo && target.windowMain ? .menu : .needs(.menu)
        case "key":
            if target.clipboard { return .needs(.clipboard) }
            if target.opens { return .needs(.opens) }
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

    /// Words of a menu item that opens something, maybe in another app (folded, so Turkish's "Aç" is "ac"): Open,
    /// Open With, Open in…, Open Recent, Reveal in Finder; Aç, Birlikte Aç, Yeni Sekmede Aç.
    static let openWords: Set<String> = ["open", "reveal", "ac"]
    /// Phrases that do: Show in Finder, and the same in Turkish.
    static let openPhrases = ["show in finder", "finder da goster"]
    /// A new window or tab (New Window, New Private Window, Yeni Sekme), which may open elsewhere: both words.
    static let newWords: Set<String> = ["new", "yeni"]
    static let windowWords: Set<String> = ["window", "tab", "pencere", "sekme", "sekmede", "pencerede"]

    /// A menu item that opens something, by its shortcut (⌘O, any other modifiers) or its title (the last part of
    /// a path). In the background it needs the window in front: what it opens could come forward.
    static func menuOpens(title: String?, character: String? = nil, modifiers: Int = 0) -> Bool {
        if modifiers & 8 == 0, character?.lowercased() == "o" { return true }
        guard let last = title.flatMap({ UIMap.menuPath($0).last }) else { return false }
        let words = UIMap.words(UIMap.fold(last))
        if words.contains(where: openWords.contains) { return true }
        if words.contains(where: newWords.contains), words.contains(where: windowWords.contains) { return true }
        let joined = " " + words.joined(separator: " ") + " "
        return openPhrases.contains { joined.contains(" " + $0 + " ") }
    }

    /// A key that opens what's selected: ⌘O anywhere, and ⌘↓ in Finder.
    static func keyOpens(_ key: UIMap.Key, finder: Bool) -> Bool {
        guard key.command else { return false }
        if key.character?.lowercased() == "o" || key.code == 31 { return true }
        return finder && key.code == 125
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
            // The whole value as it must be now: what was before the cursor, the text, and what followed the
            // selection it replaced.
            guard at >= 0, replaced >= 0, at + replaced <= was.count else { return .uncertain }
            return now == Array(was[..<at]) + new + Array(was[(at + replaced)...]) ? .done : .uncertain
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

    /// After a background act, read right before anything is put back: whether any change of it went through
    /// (`changed`: else nothing is put back, so an app the person launched before isn't undone), the app in front now
    /// (`frontNow`: the note's, or any other it opened, such as Safari for a link), and when the person last pressed
    /// a key, clicked or scrolled (uptime). Only an app that came forward with no input from the person since the
    /// baseline is undone, and only back to what was in front then. The note's app still in front, as it was: its
    /// focused window now another than the person's (`windowMoved`: the note's, or a new one it opened, such as Mail's
    /// New Message) gives them their window back.
    static func restore(_ baseline: Baseline, note: pid_t, frontNow: pid_t?, lastInput: TimeInterval, changed: Bool,
                        windowMoved: Bool) -> Restore {
        guard changed, let now = frontNow, lastInput < baseline.at, let before = baseline.front else { return .none }
        if now == before { return before == note && windowMoved ? .window : .none }
        return .app(before)
    }

    /// Something came forward in another app than the note's and the person's (a link opened in a browser, a file in
    /// its app), with no input from the person since the baseline: the AI is told, whether or not it was put back.
    /// Read right before each change that puts something back (activating the person's app, raising their window,
    /// making it main).
    struct PutBack: Equatable {
        /// Stopped (Stop, steering, a new turn, the app made private).
        var stopped: Bool
        /// When the person last pressed a key, clicked or scrolled (uptime).
        var lastInput: TimeInterval
        /// The app in front now.
        var frontNow: pid_t?
        /// The window in front in that app is still one Petal expects there: the note's, which jumped forward, or,
        /// once Petal raised theirs, theirs. Always true when putting back an app.
        var windowExpected: Bool
    }

    /// Each change of putting back goes only while nothing has moved since it was decided: no input from the person
    /// since the baseline, the app that jumped forward (`jumped`) still the one in front (not something the person
    /// chose), its window still the expected one, and not stopped. Any of those failing ends the putting back.
    static func putBack(_ seen: PutBack, baseline: Baseline, jumped: pid_t) -> Bool {
        !seen.stopped && seen.lastInput < baseline.at && seen.frontNow == jumped && seen.windowExpected
    }

    /// The restoration gate in its order: a Stop already heard reads nothing; else what's in front (`read`, through
    /// Accessibility), then the person's last input, then the Stop sampled last, right before the verdict.
    static func putBackGoes(baseline: Baseline, jumped: pid_t, stopped: () -> Bool,
                            read: () -> (front: pid_t?, windowExpected: Bool), lastInput: () -> TimeInterval) -> Bool {
        if stopped() { return false }
        let seen = read()
        let input = lastInput()
        return putBack(PutBack(stopped: stopped(), lastInput: input, frontNow: seen.front, windowExpected: seen.windowExpected),
                       baseline: baseline, jumped: jumped)
    }

    static func opened(_ baseline: Baseline, note: pid_t, frontNow: pid_t?, lastInput: TimeInterval, changed: Bool) -> Bool {
        guard changed, let now = frontNow, lastInput < baseline.at else { return false }
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
        /// Its turn for a hidden display hasn't come (RunDisplayPlan): it waits in line.
        var waitingForDisplay = false
        /// The app it waits its turn for (another run is using it on its display, or the person is using it and the
        /// run needs real keys there): its name.
        var waitingForApp: String?
    }

    /// What a run waiting its turn for a display says, wherever its state shows.
    static let waitingForDisplay = "Waiting for a display"

    /// What a run waiting its turn for an app says, wherever its state shows: "Waiting for TextEdit".
    static func waiting(for app: String) -> String { "Waiting for " + (app.isEmpty ? "an app" : app) }

    /// What a run that waits its turn says: the display first (without one it can't use the app either), then the app.
    static func turn(_ facts: Facts) -> String? {
        if facts.waitingForDisplay { return waitingForDisplay }
        return facts.waitingForApp.map { waiting(for: $0) }
    }

    /// The preview shows this many tiles side by side; more scroll sideways, none left out.
    static let tilesInView = 4
    static func previewScrolls(_ count: Int) -> Bool { count > tilesInView }

    /// Shown in the preview: working (or queued for room: `running`), waiting for the person, or done and not seen.
    static func shows(_ facts: Facts) -> Bool { facts.running || facts.ready || needsYou(facts) || turn(facts) != nil }

    /// Waiting for the person: the AI button gets a small ✦.
    static func needsYou(_ facts: Facts) -> Bool { facts.asking != nil || facts.needs != nil }

    static func line(_ facts: Facts) -> String {
        if let asking = facts.asking { return "Waiting for you: " + asking }
        if let needs = facts.needs { return "Waiting for you: " + needs }
        if let turn = turn(facts) { return turn }
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
