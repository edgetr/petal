import AppKit
import Foundation

// Checks NoteHelp.swift: what an @ line binds and asks, the helper's front matter round trip, times in words, models
// named in words, watchers' prices and lines, a notebook's memory, plain arithmetic, chained notes' loops, and the
// person's checkouts. No file, no window, no AI. Run with macos/checks/run.sh.
@main
struct NoteHelpCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Monday 9 November 2026, 10:30 UTC.
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 10, minute: 30))!
        let parts = { (date: Date) in calendar.dateComponents([.weekday, .day, .hour, .minute], from: date) }

        // MARK: Front matter values

        var file = NoteFile(id: "N1", created: now, body: "# Trip\nSome words")
        file.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: "Reading the page", asked: "@Petal check: this", mac: "mac-1", at: now)
        file.ink = [NoteHelp.Ink(who: "✦ Petal", text: "Line one\nLine two: \"quoted\"", proof: ["run.sh ✓", "diff +4 −2"], link: "https://github.com/a/b/pull/2"),
                    NoteHelp.Ink(who: "Codex", text: "The list still doesn't sort.", objections: 1)]
        file.steps = ["New worktree of ~/a", "Fixed it"]
        file.stamps = [NoteHelp.Stamp(label: "ALWAYS · GIT PUSH", grant: "rules:Bash(git push)", mac: "mac-1")]
        var watch = NoteHelp.Watch(every: "1d", line: "under $300", mac: "mac-1", at: "09:00", url: "https://shop.example/x")
        watch.record("$320", at: now)
        watch.record("$310", at: now)
        file.watch = watch
        file.task = [NoteHelp.TaskItem(kind: .tab, title: "Quote A", target: "https://a.example"), NoteHelp.TaskItem(kind: .mail, title: "Insurer", target: "message://x")]
        file.back = now
        file.fromPetal = true
        file.calc = NoteHelp.Calc(label: "Total", formula: "[Flights] + [Hotel] * 2")
        file.chain = NoteHelp.Chain(after: "R1", afterTitle: "Research", then: "N1", ask: "draft this note", mac: "mac-1", since: now)
        let text = file.serialized()
        let back = NoteFile.parse(text, fallbackID: "x", fallbackDate: now)
        expect(back == file, "every helper key reads back as written", text)
        expect(back.helper?.state == .working && back.helper?.asked == "@Petal check: this", "the helper")
        expect(back.ink.count == 2 && back.ink[0].text == "Line one\nLine two: \"quoted\"" && back.ink[0].proof == ["run.sh ✓", "diff +4 −2"], "ink with its proof")
        expect(back.ink[1].heading == "Codex · 1 objection", "a second opinion's heading", back.ink[1].heading)
        expect(back.watch?.last == "$310" && back.watch?.history == ["$320"], "a watcher: newest, the older struck", "\(String(describing: back.watch))")
        expect(back.task.count == 2 && back.task[1].kind == .mail, "a task's parts")
        expect(back.back == now && back.fromPetal, "back and from")
        expect(back.chain?.after == "R1" && back.calc?.formula == "[Flights] + [Hotel] * 2", "a chain and a formula")
        expect(back.serialized() == text, "written again, the same text")
        var cleared = back
        cleared.ink = []
        cleared.watch = nil
        expect(cleared.value("ink") == nil && cleared.value("watch") == nil && cleared.helper != nil, "a key removed, the others kept")
        // Keys a later Petal adds are still kept, and a hand-written value reads.
        let hand = "---\nid: H\nwatch:\n  every: 6h\n  line: over 50\n  mac: m\n  history:\n    - \"40\"\n    - \"30\"\nlater: kept\n---\nBody"
        let handFile = NoteFile.parse(hand, fallbackID: "x", fallbackDate: now)
        expect(handFile.watch?.every == "6h" && handFile.watch?.history == ["40", "30"], "a hand-written watcher", "\(String(describing: handFile.watch))")
        expect(handFile.serialized().contains("later: kept"), "an unknown key kept")
        expect(NoteFile.parse("---\nid: P\ncover: true\nprivate: true\n---\n", fallbackID: "x", fallbackDate: now).scalarValue("private") == "true", "a private cover, by its key")

        // MARK: Mentions

        let line = "@Petal bring @this back @Friday with @[Bus card]"
        let bound = NoteHelp.bindings(line, notes: ["Bus card", "Research"], notebooks: ["Trips"], now: now, calendar: calendar)
        expect(bound.map(\.chip) == ["", "note", "9:00", "note"], "each @ binds", "\(bound.map(\.chip))")
        if case .time(let date) = bound[2].kind { expect(parts(date).weekday == 6 && parts(date).hour == 9, "@Friday is Friday 9:00") } else { expect(false, "@Friday is a time") }
        expect(NoteHelp.mention("Bus card") == "@[Bus card]" && NoteHelp.mention("Research") == "@Research", "a name as an @ writes it")
        expect(NoteHelp.calls(line) && !NoteHelp.calls("email petal@example.com about @Research"), "only @Petal calls (an address isn't one)")
        let words = NoteHelp.bindings("@Petal look at this page tomorrow at 3pm with Opus 5.5", notes: [], notebooks: [], now: now, calendar: calendar, place: "shop.example")
        expect(words.map(\.chip) == ["", "shop.example", "15:00", "Claude"], "understood words bind too", "\(words.map(\.chip))")
        expect(NoteHelp.bindings("look at this page", notes: [], notebooks: [], now: now, calendar: calendar).isEmpty, "only on a line that calls a helper")

        // MARK: Times

        let when = { (text: String) in NoteHelp.when(text, now: now, calendar: calendar).map { parts($0.date) } }
        expect(when("Friday")?.day == 13 && when("Friday")?.hour == 9, "Friday: this Friday at 9")
        expect(when("monday")?.day == 16, "Monday, today and past: next week's")
        expect(when("today at 3pm")?.hour == 15 && when("today at 3pm")?.day == 9, "today at 3pm")
        expect(when("tomorrow 9:30")?.minute == 30 && when("tomorrow 9:30")?.day == 10, "tomorrow 9:30")
        expect(when("Friday 3")?.hour == 15, "Friday 3: the afternoon")
        expect(when("tonight")?.hour == 20, "tonight")
        expect(when("in 2 hours")?.hour == 12, "in 2 hours")
        expect(when("next week")?.weekday == 2 && when("next week")?.day == 16, "next week: Monday")
        expect(NoteHelp.backLine(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9))!, now: now, calendar: calendar) == "Back Friday 9:00", "the folded line")

        // MARK: Models

        let models = NoteHelp.models("use Opus 5.5 to fix this and have GPT 6.1 Sol look for holes")
        expect(models.count == 2, "two models", "\(models)")
        expect(models.first?.provider == .claude && models.first?.id == "claude-opus-5-5" && models.first?.holes == false, "Opus 5.5 does it", "\(String(describing: models.first))")
        expect(models.last?.provider == .codex && models.last?.id == "gpt-6.1-sol" && models.last?.holes == true, "GPT 6.1 Sol looks for holes", "\(String(describing: models.last))")
        expect(NoteHelp.models("ask sonnet").first?.id == "sonnet", "a family alone")
        expect(NoteHelp.finishLine("fix it. Done means run.sh passes. Then push") == "run.sh passes", "a finish line")

        // MARK: Requests

        let ask = { (text: String) in NoteHelp.request(text, now: now, calendar: calendar) }
        if case .bringBack(let date, _, let others) = ask(line) { expect(parts(date).weekday == 6 && others == ["Bus card"], "bring back, with another note", "\(others)") } else { expect(false, "bring back") }
        expect(ask("@Petal remember that Sam takes no sugar") == .remember("Sam takes no sugar"), "remember")
        expect(ask("@Petal forget the hotel") == .forget("the hotel"), "forget")
        expect(ask("@Petal put this away") == .putAway, "put away")
        expect(ask("@Petal check this every morning, tell me under $300") == .watch(every: "1d", at: "09:00", line: "under $300"), "a watcher", "\(ask("@Petal check this every morning, tell me under $300"))")
        expect(ask("@Petal check every 6 hours and tell me over 50") == .watch(every: "6h", at: "", line: "over 50"), "every 6 hours")
        expect(ask("@Petal make this recalculate") == .recalculate, "recalculate")
        expect(ask("when @Research is done, draft @Proposal") == .chain(after: "Research", ask: "draft this note", then: "Proposal"), "a chain", "\(ask("when @Research is done, draft @Proposal"))")
        expect(ask("@Petal check this against @Trips") == .check(against: "Trips"), "check against a notebook")
        expect(ask("@Petal leave me a note every morning at 7:30") == .morning("07:30"), "morning notes", "\(ask("@Petal leave me a note every morning at 7:30"))")
        expect(ask("@Petal what's the cheapest flight here?") == .ask("what's the cheapest flight here?"), "anything else is asked")

        // MARK: Watchers

        let page = "Lisbon → Porto 3 May · from ¥12,800 · was ¥13,500"
        let found = NoteHelp.amounts(page)
        expect(found.map(\.value) == [12800, 13500] && found[0].currency == "¥", "prices on a page", "\(found)")
        expect(NoteHelp.pick(page, line: "under ¥12k", hint: "", last: nil) == nil, "two prices, no hint: can't tell (the AI is asked)")
        expect(NoteHelp.pick(page, line: "under ¥12k", hint: "from", last: nil)?.value == 12800, "after its hint")
        expect(NoteHelp.pick(page, line: "under ¥12k", hint: "", last: 12700)?.value == 12800, "the one nearest the last value", "\(String(describing: NoteHelp.pick(page, line: "under ¥12k", hint: "", last: 12700)))")
        expect(NoteHelp.hint(before: found[0], in: page) == "· from", "the words before it", NoteHelp.hint(before: found[0], in: page))
        expect(NoteHelp.crossed(11900, line: "under ¥12k") && !NoteHelp.crossed(12800, line: "under ¥12k"), "under the line")
        expect(NoteHelp.crossed(51, line: "over 50") && !NoteHelp.crossed(50, line: "over 50"), "over the line")
        expect(NoteHelp.format(12800, currency: "¥", thousands: true) == "¥13k" && NoteHelp.format(1299.5, currency: "$", thousands: false) == "$1,299.50", "values as the line writes them")
        expect(NoteHelp.number("1.299,99") == 1299.99 && NoteHelp.number("96.400") == 96400 && NoteHelp.number("12,5") == 12.5, "numbers as people write them")
        expect(NoteHelp.pageText("<p>From <b>¥12,800</b></p><script>var x = '¥1';</script>") == "From ¥12,800", "a page's words")
        var daily = NoteHelp.Watch(every: "1d", line: "under $300", mac: "m", at: "09:00")
        expect(NoteHelp.due(daily, now: now, calendar: calendar), "never looked: due")
        daily.checked = calendar.date(byAdding: .hour, value: -1, to: now)
        expect(!NoteHelp.due(daily, now: now, calendar: calendar), "looked this morning: not again today")
        daily.checked = calendar.date(byAdding: .day, value: -1, to: now)
        expect(NoteHelp.due(daily, now: now, calendar: calendar), "yesterday's: due after 9")
        daily.paused = true
        expect(!NoteHelp.due(daily, now: now, calendar: calendar), "paused: never")
        expect(daily.foot(thisMac: true) == "Mornings · Paused" && NoteHelp.Watch(every: "1d", line: "x", mac: "m", at: "09:00").foot(thisMac: true) == "Mornings · this Mac", "the folded note's line")

        // MARK: A notebook's memory

        let cover = "# About this notebook\nA trip.\n\n## Petal remembers\n- Likes window seats\n\nEdit it like any note."
        let more = NoteHelp.remember(cover, "Sam takes no sugar")
        expect(NoteHelp.remembered(more) == ["Likes window seats", "Sam takes no sugar"], "remembered under its heading", more)
        expect(more.hasSuffix("Edit it like any note."), "the rest of the cover stays")
        expect(NoteHelp.remember(more, "sam takes no sugar") == more, "once")
        let gone = NoteHelp.forget(more, "window")
        expect(gone.removed == ["Likes window seats"] && NoteHelp.remembered(gone.cover) == ["Sam takes no sugar"], "forgotten")
        expect(NoteHelp.remembered(NoteHelp.remember("# About", "One")) == ["One"], "the heading made where there's none")

        // MARK: Arithmetic

        let body = "# Budget\nFlights: $412\nHotel: $120.50\n- Food: 60\nhttps://example.com: 3\nNotes: none"
        let values = NoteHelp.values(body)
        expect(values.map(\.label) == ["Flights", "Hotel", "Food"], "the note's values", "\(values)")
        expect(NoteHelp.evaluate("[Flights] + [Hotel] * 2", values: values) == 653, "a formula")
        expect(NoteHelp.evaluate("sum()", values: values) == 592.5, "sum")
        // `sum` with its own terms, as an AI often writes it (found by `Petal --helpers-check --ai`): those terms only,
        // each known or nothing; a comma there separates terms, and is a thousands mark only outside it.
        expect(NoteHelp.evaluate("sum([Flights], [Hotel])", values: values) == NoteHelp.evaluate("[Flights] + [Hotel]", values: values)
               && NoteHelp.evaluate("sum([Flights], [Hotel])", values: values) != nil, "sum of the terms it names")
        expect(NoteHelp.evaluate("sum([Flights], 10) * 2", values: values) == NoteHelp.evaluate("([Flights] + 10) * 2", values: values), "a term is a whole expression")
        expect(NoteHelp.evaluate("sum(1,2)", values: values) == 3 && NoteHelp.evaluate("1,200 + 1", values: values) == 1201 && NoteHelp.evaluate("sum * 2", values: values) == 1185,
               "a comma separates sum's terms, and marks thousands elsewhere; sum alone is every value")
        expect(NoteHelp.evaluate("sum([Taxi])", values: values) == nil && NoteHelp.evaluate("sum([Flights], )", values: values) == nil
               && NoteHelp.evaluate("sum([Flights]", values: values) == nil, "a term it doesn't know, or a list left open: nothing")
        expect(NoteHelp.evaluate("(Flights + Food) / 2", values: values) == 236, "one-word labels")
        expect(NoteHelp.evaluate("[Taxi] + 1", values: values) == nil && NoteHelp.evaluate("1 / 0", values: values) == nil && NoteHelp.evaluate("2 +", values: values) == nil, "never a guess")

        // MARK: Chains

        let edges = [(waiting: "B", on: "A"), (waiting: "C", on: "B")]
        expect(NoteHelp.loops(edges, adding: (waiting: "A", on: "C")), "a loop through others")
        expect(NoteHelp.loops([], adding: (waiting: "A", on: "A")), "a note waiting for itself")
        expect(!NoteHelp.loops(edges, adding: (waiting: "D", on: "C")), "a chain on")
        let chain = NoteHelp.Chain(after: "A", afterTitle: "Research", then: "B", ask: "draft", mac: "m", since: now)
        let doneLater = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", at: now.addingTimeInterval(60))
        expect(chain.ready(mac: "m", after: doneLater), "ready once its note is done after it")
        expect(!chain.ready(mac: "other", after: doneLater), "only on its own Mac")
        expect(!chain.ready(mac: "m", after: NoteHelp.Helper(state: .done, who: "", step: "", at: now.addingTimeInterval(-60))), "not for an older answer")
        var fired = chain
        fired.fired = now
        expect(!fired.ready(mac: "m", after: doneLater), "never twice")

        // MARK: Checkouts

        expect(NoteHelp.repository(url: "https://github.com/edgetr/petal/pull/16") == NoteHelp.Repository(slug: "edgetr/petal", kind: .pull, number: 16), "a pull request")
        expect(NoteHelp.repository(url: "https://github.com/edgetr/petal/issues/3")?.kind == .issue && NoteHelp.repository(url: "https://example.com/a/b") == nil, "an issue; not GitHub")
        expect(NoteHelp.pullNumber(NoteHelp.repository(url: "https://github.com/edgetr/petal/pull/16")!) == 16, "a pull request starts from its head")
        expect(NoteHelp.pullNumber(NoteHelp.repository(url: "https://github.com/edgetr/petal/issues/3")!) == nil, "an issue starts from the default branch")
        let config = "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:Edgetr/petal.git\n\tfetch = +refs/heads/*\n[branch \"main\"]\n\tremote = origin"
        expect(NoteHelp.remotes(config: config).map { "\($0.name) \($0.url)" } == ["origin git@github.com:Edgetr/petal.git"], "a git config's remotes, by name")
        expect(NoteHelp.slug(remote: "git@github.com:Edgetr/petal.git") == "edgetr/petal" && NoteHelp.slug(remote: "https://github.com/edgetr/petal") == "edgetr/petal", "remotes' slugs")
        expect(NoteHelp.slug(remote: "git@gitlab.com:a/b.git") == nil, "another host")
        let candidates: [(path: String, remotes: [(name: String, url: String)])] = [(path: "/u/petal", remotes: [(name: "origin", url: "git@github.com:edgetr/petal.git")]),
                                                                                    (path: "/u/petal-old", remotes: [(name: "origin", url: "https://github.com/edgetr/petal")]),
                                                                                    (path: "/u/site", remotes: [(name: "origin", url: "git@github.com:edgetr/edgetr.git")])]
        expect(NoteHelp.checkouts(for: "edgetr/petal", among: candidates) == ["/u/petal", "/u/petal-old"], "two checkouts: asked")
        expect(NoteHelp.inHome("/u/petal", home: "/u") && !NoteHelp.inHome("/u", home: "/u") && !NoteHelp.inHome("/tmp/x", home: "/u"), "a repository in the home folder")
        let answer = "Opened https://github.com/example/garden/pull/43 into #42.\nProof: run.sh ✓ · diff +4 −2 · PR #43"
        expect(NoteHelp.pullRequest(in: answer) == "https://github.com/example/garden/pull/43" && NoteHelp.proof(in: answer) == ["run.sh ✓", "diff +4 −2", "PR #43"], "the result and its proof")
        expect(NoteHelp.inkText(answer) == "Opened https://github.com/example/garden/pull/43 into #42.", "ink without the proof line")
        let long = String(repeating: "A long answer. ", count: 200)
        expect(NoteHelp.inkText(long) == long.trimmingCharacters(in: .whitespaces), "the whole answer is kept (only the paper shortens it)")
        expect(NoteHelp.objections(in: "1. The list in Settings still doesn't sort.\n2. No check covers it.") == 2 && NoteHelp.objections(in: "No objections.") == 0, "objections counted")
        expect(NoteHelp.taskChips([.init(kind: .tab, title: "", target: ""), .init(kind: .tab, title: "", target: ""), .init(kind: .file, title: "", target: "/a/Quote-A.pdf")]) == ["2 tabs", "Quote-A.pdf"], "a task's chips")


        // MARK: Rule A: one token carried by everything a run starts

        let token = RunToken(id: "op-1")
        final class Killed: @unchecked Sendable { var list: [String] = [] }
        let stopped = Killed()
        let lock = NSLock()
        let kill = { (what: String) in { @Sendable in lock.withLock { stopped.list.append(what) } } }
        let agentProcess = token.bind(kill("agent"))
        let gitStep = token.bind(kill("git"))
        expect(token.admits && agentProcess != nil && gitStep != nil, "a running run admits its turns, calls and git steps")
        token.unbind(gitStep)
        expect(token.pause() && !token.admits && token.paused, "paused: nothing of it is admitted")
        expect(lock.withLock { stopped.list } == ["agent"], "pausing ends what it has running (a finished step isn't touched)", "\(stopped.list)")
        expect(token.bind(kill("late")) == nil, "a step that starts while it's paused isn't admitted (and stops at once)")
        expect(token.ending(outcome: .interrupted, asking: false) == .paused && token.ending(outcome: nil, asking: false) == .paused && token.paused,
               "a turn the pause ended is a pause: nothing advances, and Go on is still there")
        expect(token.ending(outcome: .succeeded, asking: false) == .succeeded && token.ending(outcome: .succeeded, asking: true) == .paused,
               "a turn that finished cleanly before the pause reached it is a finished answer (it lands)")
        expect(token.goOn() && token.admits && !token.goOn(), "Go on: admitted again, once")
        _ = token.bind(kill("brain"))
        token.hold("always:code:/u/garden")
        expect(!token.revoke("reply") && token.admits, "another grant taken back leaves it running")
        expect(token.revoke("always:code:/u/garden") && !token.admits && token.state == .cancelled, "taking back a grant it holds cancels it")
        expect(lock.withLock { stopped.list }.contains("brain"), "and ends what it has running")
        expect(!token.goOn() && token.bind(kill("again")) == nil, "cancelled: never admitted again")
        expect(token.ending(outcome: .succeeded, asking: false) == .stopped && !token.complete(.succeeded), "a stopped run's answer counts for nothing")
        // Success only on an explicit successful outcome.
        let fresh = RunToken()
        expect(fresh.ending(outcome: nil, asking: false) == .failed, "no outcome (text, but no clean exit): failed")
        expect(fresh.ending(outcome: .failed, asking: false) == .failed, "an error event or a bad exit: failed")
        expect(fresh.ending(outcome: .interrupted, asking: false) == .stopped, "interrupted: stopped, nothing advances")
        expect(fresh.ending(outcome: .succeeded, asking: true) == .waitingOnPerson, "asking the person: not done yet")
        expect(fresh.ending(outcome: .succeeded, asking: false) == .succeeded && fresh.complete(.succeeded) && fresh.state == .finished, "a clean exit with no error: succeeded")
        expect(!fresh.complete(.succeeded) && !fresh.admits && fresh.bind({}) == nil, "finished once, never admitted again")
        // A watcher's look writes back only its own fields, and only under its own id (a UUID), not paused.
        let watchID = UUID().uuidString
        var watched: NoteHelp.Watch? = NoteHelp.Watch(every: "1d", line: "under $100", mac: "m", at: "09:00")
        watched?.id = watchID
        expect(NoteFile.parse({ var f = NoteFile(id: "W1", created: now); f.watch = watched; return f.serialized() }(), fallbackID: "x", fallbackDate: now).watch?.id == watchID,
               "a watcher's id reads back")
        expect(NoteHelp.applyLook(&watched, id: watchID, shown: "$99", amount: 99, hint: "from", past: true, confirmed: true, at: now) == true && watched?.last == "$99" && watched?.hit == false,
               "a look under its own id: written, newly crossed (the only thing that says it), not a hit until the person is told")
        expect(NoteHelp.applyLook(&watched, id: watchID, shown: "$99", amount: 99, hint: nil, past: true, confirmed: true, at: now) == true,
               "not shown yet: the next look tells them again")
        expect(NoteHelp.told(&watched, id: watchID) && watched?.hit == true, "shown to the person: the hit is kept")
        expect(NoteHelp.applyLook(&watched, id: watchID, shown: "$98", amount: 98, hint: nil, past: true, confirmed: false, at: now) == false && watched?.hit == true, "still past the line: the hit stays, not said again")
        expect(NoteHelp.applyLook(&watched, id: watchID, shown: "$120", amount: 120, hint: nil, past: false, confirmed: false, at: now) == false && watched?.hit == false, "back over the line")
        expect(NoteHelp.applyLook(&watched, id: watchID, shown: "$90", amount: 90, hint: nil, past: true, confirmed: true, at: now) == true, "crossed again after coming back: said again")
        var pausedWatch = watched
        pausedWatch?.paused = true
        pausedWatch?.id = UUID().uuidString
        let before = pausedWatch
        expect(NoteHelp.applyLook(&pausedWatch, id: watchID, shown: "$80", amount: 80, hint: nil, past: true, confirmed: true, at: now) == nil && pausedWatch == before,
               "paused meanwhile (a new id): the look writes nothing (Pause stays)")
        var samePaused = watched
        samePaused?.paused = true
        expect(NoteHelp.applyLook(&samePaused, id: watchID, shown: "$80", amount: 80, hint: nil, past: true, confirmed: true, at: now) == nil, "paused under the same id: nothing either")
        var stoppedWatch: NoteHelp.Watch? = nil
        expect(NoteHelp.applyLook(&stoppedWatch, id: watchID, shown: "$80", amount: 80, hint: nil, past: true, confirmed: true, at: now) == nil && stoppedWatch == nil, "stopped meanwhile: nothing comes back")
        // Its place: the one in front, else wait for it (never what happens to be in front).
        var tabPlace = NoteStick(kind: .tab)
        tabPlace.url = "https://shop.example/x"
        var deskPlace = NoteStick(kind: .desktop)
        deskPlace.desktop = 2
        expect(NoteHelp.anchor([deskPlace, tabPlace], here: 1) == .placed(1), "placed on its window: that place")
        expect(NoteHelp.anchor([deskPlace, tabPlace], here: nil) == .away("shop.example/x"), "brought back on the Desktop: it waits for its page")
        expect(NoteHelp.anchor([deskPlace, tabPlace], here: 0) == .away("shop.example/x"), "shown on a Desktop: still waits for its page")
        expect(NoteHelp.anchor([deskPlace], here: nil) == .free && NoteHelp.anchor([], here: nil) == .free, "only on a Desktop, or nowhere: free")

        // MARK: Rule B: what a helper tells an AI is Shielded (only NoteShield makes it)

        let secret = "4111 1111 1111 1111"
        let index = UIMap.SecretIndex([secret])
        let digits = String(secret.prefix(9))
        let raws = ["pay with \(secret) please",
                     "# Card \(secret) and more words after it, enough that the title would be cut right through the middle of a secret if cut first\nBody \(secret)",
                     "Book \(secret)", "Remembers \(secret)", "Chained answer \(secret)", "It said \(secret)", "under $1 \(secret)", "$2 \(secret)"]
        guard let shown = NoteShield.shield(raws, index: index), let labels = NoteShield.shield(["Tab \(secret)"], index: index),
              let paths = NoteShield.shield(["~/g", "/t \(secret)", "b", ""], index: index) else { return expect(false, "shielding") }
        var stick = NoteStick(kind: .passage)
        stick.url = "https://shop.example/\(secret.replacingOccurrences(of: " ", with: ""))"
        stick.appName = "Shop"
        stick.quote = String(repeating: "x", count: 390) + secret + " tail"
        guard let place = NoteShield.place(stick, appPrivate: false, index: index) else { return expect(false, "a place") }
        var told = NoteHelp.Told(ask: shown[0], body: shown[1], notebook: shown[2], cover: shown[3], place: place.words, quote: place.quote, extra: shown[4],
                                 answer: shown[5], titles: labels, line: shown[6], last: shown[7], paths: paths)
        let pageWords = told.extra
        let prompts: [Shielded] = [NoteHelp.brief(told), NoteHelp.codeBrief(told), NoteHelp.codeRequest(told), NoteHelp.reviewRequest(told, tree: told.paths[1]),
                                   NoteHelp.reviewBrief(told), NoteHelp.formulaRequest(told), NoteHelp.awayRequest(told),
                                   NoteHelp.watchConfirm(told, found: pageWords.substring(NSRange(location: 0, length: 7)), hint: pageWords.substring(NSRange(location: 8, length: 6))),
                                   NoteHelp.watchFind(told)]
        expect(prompts.allSatisfy { !$0.text.contains(digits) }, "no prompt carries the secret, whole or cut", prompts.first { $0.text.contains(digits) }?.text ?? "")
        expect(NoteHelp.brief(told).text.contains("Book (hidden)") || NoteHelp.brief(told).text.contains("Book "), "redacted, then said")
        expect(!told.body.title.text.contains(digits), "the title derived after redaction", told.body.title.text)
        expect(NoteHelp.codeBrief(told).text.contains("read it first") && NoteHelp.reviewBrief(told).text.contains("read it first"), "coding helpers and second opinions read the cover first")
        // Follow-ups, Go on and watcher fields go through it too: a follow-up's words, the line and last value.
        guard let follow = NoteShield.shield(["and also \(secret)"], index: index) else { return expect(false, "a follow-up") }
        expect(!follow[0].text.contains(digits) && !told.line.text.contains(digits) && !told.last.text.contains(digits), "a follow-up and a watcher's line and last value are redacted")
        // An app kept private: only what the place is, never its words or sentence.
        var privateStick = NoteStick(kind: .passage)
        privateStick.app = "com.example.private"
        privateStick.appName = "Diary"
        privateStick.title = "My secret window"
        privateStick.quote = "a private sentence"
        guard let hidden = NoteShield.place(privateStick, appPrivate: true, index: index) else { return expect(false, "a private place") }
        expect(!hidden.words.text.contains("secret window") && hidden.quote.isEmpty, "a private app's place: its words and sentence never told", hidden.words.text)
        expect(NoteShield.shield(["x"], index: .unavailable) == nil && NoteShield.place(stick, appPrivate: false, index: .unavailable) == nil, "the vault unreadable: nothing told")
        told.place = ""
        expect(NoteHelp.brief(told).text.contains("isn't on a window now"), "a note on no window is told not to look in front")
        let literal: Shielded = "Go on where you stopped."
        expect(literal.text == "Go on where you stopped." && ("a \(literal) \(3)" as Shielded).text == "a Go on where you stopped. 3", "Petal's own words and numbers interpolate")

        // The helper's whole system prompt: only Shielded parts (no raw window or tab title).
        var systemTold = told
        systemTold.place = place.words
        guard let notes = NoteShield.shield(["Use metric \(secret)", "Likes short answers \(secret)"], index: index) else { return expect(false, "notes") }
        systemTold.instructions = notes[0]
        systemTold.memory = notes[1]
        let system = NoteHelp.system(systemTold, provider: "Claude", computerUse: true, brief: NoteHelp.brief(systemTold))
        expect(!system.text.contains(digits) && system.text.contains("You are Claude") && system.text.contains("The note is on:") && system.text.contains("Use metric (hidden)"),
               "the system prompt: shielded place, notes and memory, then the brief", system.text.prefix(300).description)
        // Checking against a notebook: each note shielded whole, then titled and cut.
        let longSecretNote = "# Plan \(secret)\n" + String(repeating: "y", count: 1995) + secret + " end"
        guard let sources = NoteShield.shield([longSecretNote, "# Other\nfine"], index: index), let book = NoteShield.shield(["Trips \(secret)"], index: index) else { return expect(false, "sources") }
        systemTold.sources = sources
        systemTold.sourceBook = book[0]
        let compared = NoteHelp.comparison(systemTold)
        expect(!compared.text.contains(digits) && !compared.text.contains("4111") && compared.text.contains("## Plan (hidden)") && compared.text.contains("## Other"),
               "a notebook's notes: shielded whole first, titles and cuts after", compared.text.prefix(200).description)
        expect(NoteHelp.brief(systemTold).text.contains("The notebook Trips"), "the comparison is in the brief")

        // MARK: Three outcomes, reported once

        let ok = RunToken()
        expect(ok.complete(.succeeded) && ok.completion == .succeeded && !ok.complete(.failed("late")) && ok.completion == .succeeded, "succeeded, once")
        let failing = RunToken()
        let failedStop = Killed()
        _ = failing.bind { lock.withLock { failedStop.list.append("x") } }
        expect(failing.complete(.failed("no API key")) && failing.completion == .failed("no API key") && !failing.admits, "failed, with its reason: nothing more admitted")
        expect(lock.withLock { failedStop.list } == ["x"] && !failing.complete(.succeeded), "failing ends what it has running, and can't succeed after")
        let pausedRun = RunToken()
        pausedRun.pause()
        expect(pausedRun.complete(.stopped) && pausedRun.completion == .stopped && !pausedRun.complete(.succeeded), "a paused run can be stopped, and can't succeed after")
        // Chains and reviewers consume only succeeded.
        let chainAfter = NoteHelp.Chain(after: "A", afterTitle: "Research", then: "B", ask: "draft", mac: "m", since: now)
        expect(!chainAfter.ready(mac: "m", after: NoteHelp.Helper(state: .failed, who: "", step: "no API key", at: now.addingTimeInterval(60))), "a chain ignores a failed note")
        expect(chainAfter.ready(mac: "m", after: NoteHelp.Helper(state: .done, who: "", step: "", at: now.addingTimeInterval(60))), "and starts on a done one")
        var failedFile = NoteFile(id: "F", created: now)
        failedFile.helper = NoteHelp.Helper(state: .failed, who: "✦ Petal", step: "no API key", at: now)
        expect(NoteFile.parse(failedFile.serialized(), fallbackID: "x", fallbackDate: now).helper?.state == .failed, "failed reads back")

        // MARK: Tokens by what they're for: watcher looks, shared grants, Go on

        let table = TokenTable()
        let look1 = table.start("watch:A")
        let look2 = table.start("watch:A")
        expect(look1.state == .cancelled && look2.admits, "a new look cancels the one before it")
        table.cancel("watch:A")
        expect(look2.state == .cancelled && table.token("watch:A") == nil, "pausing, stopping or changing a watcher cancels its look")
        let runA = table.start("A"), runB = table.start("B"), runC = table.start("C")
        runA.hold("always:code:/u/garden")
        runB.hold("always:code:/u/garden")
        runC.hold("reply")
        expect(table.revoke("always:code:/u/garden") == ["A", "B"] && runA.state == .cancelled && runB.state == .cancelled && runC.admits,
               "a shared grant taken back cancels every run holding it, whichever note")
        table.finish("C", runB)
        expect(table.token("C") === runC, "finishing another token leaves the current one")
        expect(NoteHelp.goOn(launched: false, waitingTurn: false, restartable: true) == .restart, "a quick run (no agent) is begun again on Go on")
        expect(NoteHelp.goOn(launched: false, waitingTurn: false, restartable: false) == .stopped, "one that can't be begun again: Pause stops it")
        expect(NoteHelp.goOn(launched: true, waitingTurn: true, restartable: true) == .startWaiting && NoteHelp.goOn(launched: true, waitingTurn: false, restartable: false) == .carryOn,
               "a launched run: its waiting turn starts, or it carries on")

        // MARK: Metadata rebase, place follow, stored branch, the remote's default branch

        var typed = NoteFile(id: "R", created: now, body: "My words")
        let baseText = typed.serialized()
        typed.ink = [NoteHelp.Ink(who: "✦ Petal", text: "An answer")]
        typed.helper = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", at: now)
        let helperText = typed.serialized()
        expect(NoteShelf.rebase(editor: baseText, current: helperText, currentBody: typed.body) == helperText,
               "a helper's metadata write: the person's next save is made on it (no conflict)")
        expect(NoteShelf.rebase(editor: baseText, current: helperText, currentBody: "Other words") == baseText, "words changed elsewhere: still a conflict")
        var tabA = NoteStick(kind: .tab)
        tabA.url = "https://a.example"
        tabA.mac = "m"; tabA.pid = 5; tabA.tabID = "t1"
        var tabB = tabA
        tabB.url = "https://b.example"; tabB.tabID = "t2"
        var titled = tabA
        titled.title = "A new title"
        expect(NoteHelp.placesMoved([tabA], [tabB]) && NoteHelp.placesMoved([tabA], [tabA, tabB]) && NoteHelp.placesMoved([tabA, tabB], [tabA]),
               "re-stuck, a place added or taken off: followed")
        expect(!NoteHelp.placesMoved([tabA], [titled]), "the same place with a newer title: not a move")
        let stored = NoteHelp.Worktree(path: "/t", branch: "petal/first-words-3f2a9c1d", checkout: "/u/garden", remote: "origin")
        expect(NoteHelp.branch(stored: stored, checkout: "/u/garden/", noteID: "3F2A9C1D-0000-4000-8000-000000000001", words: "different words now") == "petal/first-words-3f2a9c1d",
               "a follow-up uses the branch stored when the worktree was made")
        expect(NoteHelp.branch(stored: stored, checkout: "/u/other", noteID: "3F2A9C1D-0000-4000-8000-000000000001", words: "fix it").hasPrefix("petal/fix-it-"), "another checkout: a branch of its own")
        expect(NoteHelp.defaultBranch(lsRemote: "ref: refs/heads/trunk\tHEAD\nabc123\tHEAD\n") == "trunk", "the default branch, from the remote")
        expect(NoteHelp.defaultBranch(lsRemote: "abc123\tHEAD\n") == nil && NoteHelp.defaultBranch(lsRemote: "") == nil, "the remote doesn't say: none (nothing is made)")
        expect(NoteHelp.defaultBranch(lsRemote: "ref: refs/heads/main\trefs/remotes/x\n") == nil, "only HEAD's")

        // MARK: Privacy: open, private or unknown

        var openCover = NoteFile(id: "C1", created: now)
        openCover.cover = true
        var closedCover = openCover
        closedCover.set("private", .text("true"))
        expect(!NoteContract.isPrivate(openCover) && NoteContract.isPrivate(closedCover), "a cover's private key, by name")
        // One rule for Private notebooks, Phase 3's (NoteLibrary.privateNotebook, NotePrivacy): only files named like the
        // cover count, and one not read is unknown, which counts as Private.
        expect(!NoteLibrary.privateNotebook(covers: [openCover], unread: false) && NoteLibrary.privateNotebook(covers: [closedCover], unread: false), "a cover read: open or private")
        expect(!NoteLibrary.privateNotebook(covers: [], unread: false), "no cover file at all: open (nothing says private)")
        expect(NoteLibrary.privateNotebook(covers: [openCover], unread: true) && NoteLibrary.notebookUnknown(listed: true, unreadCovers: 1), "a cover file unread, dataless or unreadable: unknown, so Private")
        expect(NoteLibrary.notebookUnknown(listed: false, unreadCovers: 0), "the folder couldn't be listed: unknown")
        expect(NoteLibrary.privateNotebook(covers: [openCover, closedCover], unread: false), "a cover and its conflict copy disagree: private")
        expect(NoteLibrary.isCoverName("About this notebook.md") && NoteLibrary.isCoverName("About this notebook (conflicted copy).md") && NoteLibrary.isCoverName("about this notebook 2.MD"),
               "the cover and its copies, by name")
        expect(!NoteLibrary.isCoverName("Plan.md") && !NoteLibrary.isCoverName("About this notebook.txt") && !NoteLibrary.isCoverName("Notes about this notebook.md"), "nothing else is a cover")
        expect(NoteHelp.isCoverPlaceholder(".About this notebook.md.icloud") && !NoteHelp.isCoverPlaceholder(".Plan.md.icloud"), "a cover not downloaded (its iCloud placeholder)")
        expect(NotePrivacy.readable(notebook: "B", privateBooks: ["A"], asker: nil) && !NotePrivacy.readable(notebook: "A", privateBooks: ["A"], asker: "B")
               && !NotePrivacy.readable(notebook: "A", privateBooks: ["A"], asker: nil),
               "unknown is private from outside")
        expect(NotePrivacy.readable(notebook: "A", privateBooks: ["A"], asker: "A"), "a note inside it reads it")

        // MARK: Paths, remotes, watcher words, local times, branches

        let home = "/Users/someone"
        let garden = ["/Users/someone/garden", "/Users/someone/garden-old"]
        expect(NoteHelp.named(garden, in: "@Petal fix it in ~/garden", home: home) == "/Users/someone/garden", "~/garden is ~/garden")
        expect(NoteHelp.named(garden, in: "@Petal fix it in ~/garden-old.", home: home) == "/Users/someone/garden-old", "~/garden-old is ~/garden-old, never ~/garden")
        expect(NoteHelp.named(garden, in: "in ~/garden/ please", home: home) == "/Users/someone/garden", "a trailing slash is the same path")
        expect(NoteHelp.named(garden, in: "in ~/gard", home: home) == nil && NoteHelp.named(garden, in: "fix it", home: home) == nil, "a part of a name, or none: nothing")
        expect(NoteHelp.named(garden, in: "~/garden or ~/garden-old", home: home) == nil, "two named: neither")
        let remotes = [(name: "fork", url: "git@github.com:someone/garden.git"), (name: "upstream", url: "https://github.com/example/garden")]
        expect(NoteHelp.remote(for: "example/garden", in: remotes) == "upstream", "the remote that is the PR's repository, not origin by default")
        expect(NoteHelp.remote(for: "example/garden", in: [(name: "origin", url: "git@github.com:example/garden.git")] + remotes) == "origin", "origin first when it's that repository")
        expect(NoteHelp.remote(for: "other/repo", in: remotes) == nil, "no remote for another repository")
        expect(NoteHelp.watchWords("check whether it's under $300") == nil, "a plain check is asked once")
        expect(ask("@Petal check if this is under $300") == .ask("check if this is under $300"), "a one-time check is a helper run")
        expect(NoteHelp.watchWords("tell me when it's under $300")?.line == "under $300" && NoteHelp.watchWords("keep checking, under $300") != nil, "tell me when, keep checking: a watcher")
        expect(NoteHelp.watchWords("check each morning, tell me under $300")?.every == "1d", "each morning: a watcher")
        expect(NoteHelp.watchWords("every morning at 7:30 tell me under $300")?.at == "07:30", "its clock as said", "\(String(describing: NoteHelp.watchWords("every morning at 7:30 tell me under $300")))")
        expect(NoteHelp.watchWords("every evening at 6pm tell me over 50")?.at == "18:00", "6pm is 18:00, whatever the time zone")
        expect(NoteHelp.clockParts("12am")! == (0, 0) && NoteHelp.clockParts("noon")! == (12, 0) && NoteHelp.clockParts("25:00") == nil, "clock words")
        // 07:30 said in Tokyo is 07:30 in Tokyo: due after it there, not before.
        var tokyo = NoteHelp.Watch(every: "1d", line: "under $1", mac: "m", at: "07:30")
        tokyo.tz = "Asia/Tokyo"
        tokyo.checked = now.addingTimeInterval(-3 * 86400)
        let tokyoMorning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 22, minute: 45))!   // 07:45 in Tokyo, 10 Nov
        let tokyoNight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 21, minute: 0))!      // 06:00 in Tokyo
        expect(NoteHelp.due(tokyo, now: tokyoMorning, calendar: calendar) && !NoteHelp.due(tokyo, now: tokyoNight, calendar: calendar), "a watcher's time is its own clock, in its own time zone")
        let id = "3F2A9C1D-0000-4000-8000-000000000001"
        let branch = NoteHelp.branch(noteID: id, words: "use Opus 5.5 to fix the date picker")
        expect(branch == "petal/opus-5-5-3f2a9c1d", "a branch from the note's id and a few words", branch)
        expect(NoteHelp.branch(noteID: id, words: "fix the date picker") != NoteHelp.branch(noteID: "8C1D0000-0000-4000-8000-000000000002", words: "fix the date picker"),
               "two notes asking alike: two branches")
        expect(NoteHelp.branch(noteID: id, words: "").hasSuffix("-3f2a9c1d") && NoteHelp.branch(noteID: id, words: "日本語").hasPrefix("petal/note-"), "always the note's key")
        let gardenTree = NoteHelp.worktreeName(checkout: "/Users/someone/garden", noteID: id)
        expect(gardenTree.hasPrefix("garden-") && gardenTree.hasSuffix("-3f2a9c1d"), "one worktree per note", gardenTree)
        expect(NoteHelp.worktreeName(checkout: "/Users/someone/Projects/garden", noteID: id) != gardenTree, "two checkouts named alike: two worktrees")
        expect(NoteHelp.worktreeName(checkout: "/Users/someone/garden/", noteID: id) == gardenTree, "the same checkout, however it's written")
        expect(NoteHelp.reusable(expectedCommon: "/Users/someone/garden/.git", actualCommon: "/Users/someone/garden/.git/", branch: "petal/x-3f2a9c1d", actualBranch: "petal/x-3f2a9c1d"),
               "reused when it's that checkout's, on the note's branch")
        expect(!NoteHelp.reusable(expectedCommon: "/Users/someone/garden/.git", actualCommon: "/Users/someone/Projects/garden/.git", branch: "b", actualBranch: "b"), "never another checkout's")
        expect(!NoteHelp.reusable(expectedCommon: "/a/.git", actualCommon: "/a/.git", branch: "b", actualBranch: "main") && !NoteHelp.reusable(expectedCommon: "/a/.git", actualCommon: nil, branch: "b", actualBranch: "b"),
               "never on another branch, or when git couldn't say")
        expect(NoteHelp.fetchRef("op-1") == "refs/petal/op-1" && NoteHelp.fetchRef("A/B C") != NoteHelp.fetchRef("op-1"), "each run fetches into a ref of its own")
        expect(NoteHelp.noteKey("file:Inbox/a.md").count == 8 && NoteHelp.noteKey("file:Inbox/a.md") != NoteHelp.noteKey("file:Inbox/b.md"), "an id-less note's key is a hash")
        var withTree = NoteFile(id: "W", created: now)
        withTree.worktree = NoteHelp.Worktree(path: "/t/garden-w", branch: "petal/x-w", checkout: "/u/garden", remote: "upstream")
        expect(NoteFile.parse(withTree.serialized(), fallbackID: "x", fallbackDate: now).worktree == withTree.worktree, "a note's worktree reads back")
        expect(ask("@Petal it's done") == .done, "it's done")

        // MARK: Round four: follow-ups, auth, automatic approvals, checkout choice, quick calls, place follow

        var queue = FollowUpQueue<String>()
        let first = RunToken(), later = RunToken()
        // (What's said waits as the person wrote it, a raw source: shielded only when its turn starts.)
        let said = ["and also this"]
        queue.add(said[0], note: "N", token: first)
        queue.add(said[0], note: "N", token: first)
        expect(queue.next(note: "N", current: first)?.text == said[0] && queue.count(note: "N") == 1, "a follow-up goes in its own run")
        first.complete(.stopped)
        queue.clear(first)
        expect(queue.count(note: "N") == 0, "Stop clears what was said to its run")
        queue.add(said[0], note: "N", token: first)
        expect(queue.next(note: "N", current: later) == nil && queue.count(note: "N") == 0, "said to a stopped run: never sent in a later one (dropped)")
        let pausedFollow = RunToken()
        pausedFollow.pause()
        queue.add(said[0], note: "N", token: pausedFollow)
        expect(queue.next(note: "N", current: pausedFollow) == nil, "a run not running admits none")
        expect(RunToken.classify(authFailed: true, errored: false, signaled: true, status: 15) == .failed, "a sign-in failure is a failure, though its process was stopped for it")
        expect(RunToken.classify(authFailed: false, errored: false, signaled: true, status: 15) == .interrupted, "a plain stop is an interruption")
        expect(RunToken.classify(authFailed: false, errored: true, signaled: false, status: 0) == .failed
               && RunToken.classify(authFailed: false, errored: false, signaled: false, status: 0) == .succeeded, "an error event fails; a clean exit succeeds")
        expect(NoteHelp.autoGrant(kind: "computer:com.example", fullAccess: false, allowed: ["computer:com.example"]) == "always:computer:com.example",
               "an Always given earlier is registered as that grant")
        expect(NoteHelp.autoGrant(kind: "trash", fullAccess: true, allowed: []) == "full-access" && NoteHelp.autoGrant(kind: "trash", fullAccess: false, allowed: []) == nil,
               "Full access, or asked")
        let autoRun = RunToken()
        autoRun.hold(NoteHelp.autoGrant(kind: "computer:com.example", fullAccess: false, allowed: ["computer:com.example"])!)
        expect(autoRun.revoke("always:computer:com.example") && autoRun.state == .cancelled, "taking that Always back cancels a run that used it automatically")
        let home2 = "/Users/someone"
        expect(NoteHelp.chooseCheckout(["/Users/someone/garden"], words: "fix it in ~/garden-old", home: home2) == .mismatch("/Users/someone/garden-old"),
               "one candidate, another named: fails, never the one candidate")
        expect(NoteHelp.chooseCheckout(["/Users/someone/garden"], words: "fix it in ~/garden", home: home2) == .one("/Users/someone/garden"), "one candidate, named: it")
        expect(NoteHelp.chooseCheckout(["/Users/someone/garden"], words: "fix it", home: home2) == .one("/Users/someone/garden"), "one candidate, none named: it")
        expect(NoteHelp.chooseCheckout(["/a", "/b"], words: "fix it", home: home2) == .ask(["/a", "/b"]) && NoteHelp.chooseCheckout([], words: "fix it", home: home2) == .none,
               "several, none named: asked; none: none")
        let calcValues = NoteHelp.values("Flights: 400\nHotel: 200")
        expect(NoteHelp.formulaOutcome(["label": "Total", "formula": "[Flights] + [Hotel]"], values: calcValues).calc?.formula == "[Flights] + [Hotel]", "a formula that adds up: succeeded")
        expect(NoteHelp.formulaOutcome(nil, values: calcValues).calc == nil && NoteHelp.formulaOutcome(nil, values: calcValues).failure != nil, "no answer: failed")
        expect(NoteHelp.formulaOutcome(["label": "Total"], values: calcValues).calc == nil, "no formula: failed (never sum() instead)")
        expect(NoteHelp.formulaOutcome(["formula": "[Taxi] * 2"], values: calcValues).calc == nil, "a formula that doesn't add up here: failed")
        expect(NoteHelp.confirmed(["yes": true]) && !NoteHelp.confirmed(nil) && !NoteHelp.confirmed(["yes": "true"]) && !NoteHelp.confirmed(["say": "it is"]) && !NoteHelp.confirmed(["yes": false]),
               "a watcher's hit needs an explicit, valid yes")
        var oldTab = NoteStick(kind: .tab)
        oldTab.url = "https://old.example"; oldTab.mac = "m"; oldTab.pid = 5; oldTab.tabID = "t1"
        var newTab = oldTab
        newTab.url = "https://new.example"; newTab.tabID = "t2"
        expect(NoteHelp.follow(seen: [oldTab], now: [newTab], here: nil) == .waiting("new.example"), "re-stuck to a tab not in front: it waits (its look and act refused)")
        expect(NoteHelp.follow(seen: [oldTab], now: [newTab], here: 0) == .placed(0), "once here says it's in front: that place")
        expect(NoteHelp.follow(seen: [oldTab], now: [oldTab], here: 0) == .unchanged, "unchanged")

        // MARK: Round five: follow-up checkout binding, scoped grants, watcher confirmation, providers, proof

        let gardenHome = "/Users/someone"
        expect(NoteHelp.followUpTarget(runCheckout: "/Users/someone/garden", words: "also fix the header", home: gardenHome) == .same, "a follow-up naming nothing: its run")
        expect(NoteHelp.followUpTarget(runCheckout: "/Users/someone/garden", words: "and in ~/garden too", home: gardenHome) == .same, "naming its own checkout: its run")
        expect(NoteHelp.followUpTarget(runCheckout: "/Users/someone/garden", words: "now do it in ~/garden-old", home: gardenHome) == .newRun,
               "naming another checkout: a new run (its own choice and Allow), never the existing agent")
        let onceA = NoteHelp.onceGrant(kind: "computer:com.apple.Safari", note: "A", run: "r1")
        let onceB = NoteHelp.onceGrant(kind: "computer:com.apple.Safari", note: "B", run: "r2")
        expect(onceA != onceB && onceA != NoteHelp.onceGrant(kind: "computer:com.apple.Safari", note: "A", run: "r3"), "Allow once: its note's and run's alone")
        let grants = TokenTable()
        let noteA = grants.start("A"), noteB = grants.start("B")
        noteA.hold(onceA); noteB.hold(onceB)
        noteA.hold("always:computer:com.apple.Safari"); noteB.hold("always:computer:com.apple.Safari")
        expect(grants.revoke(onceA) == ["A"] && noteB.admits, "taking back one note's Allow once stops only its run")
        let noteC = grants.start("C")
        noteC.hold("always:computer:com.apple.Safari")
        expect(grants.revoke("always:computer:com.apple.Safari") == ["B", "C"], "a real Always is shared: every run using it stops")
        let rulesGrant = NoteHelp.rulesGrant(["Bash(git push)", "Bash(npm test)"], note: "A", run: "r1")
        expect(NoteHelp.Stamp(label: "x", grant: rulesGrant, mac: "m").parsed == .rules(rulesGrant) && rulesGrant.hasPrefix("rules:A:r1:"), "a run's rules: scoped, by an opaque id")
        expect(NoteHelp.Stamp(label: "x", grant: onceA, mac: "m").parsed == .once(onceA) && NoteHelp.Stamp(label: "x", grant: "always:trash", mac: "m").parsed == .always("trash"), "grants read")
        expect(NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: nil, asked: false) == .unconfirmed, "the quick AI off: crossed, but not confirmed (never a hit)")
        expect(NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: nil, asked: true) == .unconfirmed, "no answer: not confirmed")
        expect(NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: ["say": "it is"], asked: true) == .unconfirmed, "an answer without an explicit yes: not confirmed")
        expect(NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: ["yes": false], asked: true) == .refuted, "an explicit no: nothing")
        expect(NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: ["yes": true], asked: true) == .hit, "an explicit yes: a hit")
        expect(NoteHelp.watchVerdict(crossed: false, alreadyHit: false, confirmation: ["yes": true], asked: true) == .plain
               && NoteHelp.watchVerdict(crossed: true, alreadyHit: true, confirmation: ["yes": true], asked: true) == .plain, "not crossed, or a hit already: just the value")
        expect(NoteHelp.providerChoice(named: .codex, available: ["claude"], chat: "claude") == .missing("Codex"), "Codex named but not set up: fails, never Claude instead")
        expect(NoteHelp.providerChoice(named: .claude, available: ["claude", "codex"], chat: "codex") == .use("claude"), "the one named")
        expect(NoteHelp.providerChoice(named: nil, available: ["claude", "codex"], chat: "codex") == .use("codex") && NoteHelp.providerChoice(named: nil, available: [], chat: "codex") == .none,
               "none named: the chat's AI, or none")
        let noProof = NoteHelp.codeInk(who: "Opus 5.5", answer: "Fixed it and pushed.", finish: "the tests pass")
        expect(noProof.proof.isEmpty && noProof.missingProof && noProof.finish == "the tests pass", "no Proof: line: no proof (never the finish line as a badge), said plainly")
        let proved = NoteHelp.codeInk(who: "Opus 5.5", answer: "Fixed it.\nProof: tests ✓ · diff +1 −1", finish: "the tests pass")
        expect(proved.proof == ["tests ✓", "diff +1 −1"] && !proved.missingProof && proved.finish == "the tests pass", "its own proof, the finish line apart")
        expect(NoteHelp.Ink(proved.value) == proved, "a coding ink reads back")
        expect(!NoteHelp.Ink(who: "✦ Petal", text: "Hi").missingProof, "a helper that isn't coding has no proof to miss")

        // MARK: Round six: run-scoped rules, documents, hit persistence, providers in follow-ups, post-wait privacy

        var rules = RunScoped<[String]>([])
        let runOne = RunToken(), runTwo = RunToken()
        rules.adopt(runOne)
        rules.value.append("Bash(git push)")
        rules.adopt(runOne)
        expect(rules.value == ["Bash(git push)"], "a continuation of the same run keeps its command rules")
        rules.adopt(runTwo)
        expect(rules.value.isEmpty, "a new run on the same note starts with none")
        rules.value = ["Bash(npm test)"]
        rules.adopt(nil)
        expect(rules.value.isEmpty, "no run: none")
        // A file helper's document is the one showing by the one file resolver's answer (NoteMatch.fits, what the
        // helpers' gate asks): the very file by its `fileID`, a file renamed is still it, and another file that took
        // its path is not; never a path compared.
        var talkPlace = NoteStick(kind: .file)
        talkPlace.path = "/Users/someone/Talk.key"
        talkPlace.fileID = "mac-1|VOL|41|1000"
        var talkScene = NoteScene(mac: "mac-1", app: "com.apple.iWork.Keynote", pid: 7, window: 3, title: "Talk")
        talkScene.file = "/Users/someone/Talk.key"
        talkScene.fileID = "mac-1|VOL|41|1000"
        expect(NoteMatch.fits(talkPlace, talkScene), "its file showing: its place is good")
        talkScene.file = "/Users/someone/Talk final.key"
        expect(NoteMatch.fits(talkPlace, talkScene), "its file renamed (the same file, another path): still its place")
        talkScene.file = "/Users/someone/Talk.key"
        talkScene.fileID = "mac-1|VOL|77|2000"
        talkScene.onFile = []
        expect(!NoteMatch.fits(talkPlace, talkScene), "another file that took its path: not its place (it waits)")
        talkScene.file = ""
        expect(!NoteMatch.fits(talkPlace, talkScene), "no document read: not its place")
        var held: NoteHelp.Watch? = NoteHelp.Watch(every: "1d", line: "under $100", mac: "m", at: "09:00")
        held?.id = "W"
        expect(NoteHelp.applyLook(&held, id: "W", shown: "$95", amount: 95, hint: nil, past: true, confirmed: true, at: now) == true && NoteHelp.told(&held, id: "W") && held?.hit == true, "confirmed and told: a hit")
        expect(NoteHelp.applyLook(&held, id: "W", shown: "$94", amount: 94, hint: nil, past: true, confirmed: false, at: now) == false && held?.hit == true,
               "still past the line, nothing confirmed this time: the hit stays (never re-armed)")
        expect(NoteHelp.applyLook(&held, id: "W", shown: "$93", amount: 93, hint: nil, past: true, confirmed: true, at: now) == false, "still past and confirmed again: not said again")
        expect(NoteHelp.applyLook(&held, id: "W", shown: "$105", amount: 105, hint: nil, past: false, confirmed: false, at: now) == false && held?.hit == false, "back over the line: cleared")
        expect(NoteHelp.applyLook(&held, id: "W", shown: "$90", amount: 90, hint: nil, past: true, confirmed: false, at: now) == false && held?.hit == false, "past again but not confirmed: no hit")
        let routeHome = "/Users/someone"
        expect(NoteHelp.followUpTarget(runCheckout: nil, runProvider: "claude", runModel: "", words: "and make it shorter", home: routeHome) == .same, "naming nothing: steers its run")
        expect(NoteHelp.followUpTarget(runCheckout: nil, runProvider: "claude", runModel: "", words: "now ask Codex", home: routeHome) == .newRun,
               "naming another AI: its own run (or not set up), never steering this one")
        expect(NoteHelp.followUpTarget(runCheckout: nil, runProvider: "claude", runModel: "claude-opus-5-5", words: "use Sonnet for this", home: routeHome) == .newRun, "another model: its own run")
        expect(NoteHelp.followUpTarget(runCheckout: nil, runProvider: "claude", runModel: "claude-opus-5-5", words: "keep using Opus 5.5", home: routeHome) == .same, "its own model: its run")
        expect(NoteHelp.followUpTarget(runCheckout: "/Users/someone/garden", runProvider: "claude", runModel: "", words: "in ~/garden-old", home: routeHome) == .newRun, "another checkout: its own run")
        var privateNow: Set<String> = []
        let lookedUp: Set<String> = ["Trips", "Diary"]
        expect(NotePrivacy.deliverable(notebooks: lookedUp, privateBooks: privateNow, asker: nil), "before the wait: both")
        privateNow = ["Diary"]
        expect(!NotePrivacy.deliverable(notebooks: lookedUp, privateBooks: privateNow, asker: nil) && NotePrivacy.deliverable(notebooks: ["Trips"], privateBooks: privateNow, asker: nil),
               "made private during the wait: not told")
        expect(NotePrivacy.deliverable(notebooks: ["Diary"], privateBooks: privateNow, asker: "Diary"), "a note inside it still reads it")
        expect(NotePrivacy.privateBooks(notebooks: [(name: "Diary", isPrivate: true)], held: ["Trips"]) == ["Diary", "Trips"], "a notebook the read didn't find: unknown, not told")

        // MARK: Round seven: the admission gate, answers kept through a conflict, reviewers, bounds, completions

        var facts = NoteHelp.GateFacts()
        facts.notebook = "Work"; facts.startNotebook = "Work"
        facts.provider = "claude"; facts.available = ["claude"]
        expect(NoteHelp.admit(facts) == .go, "all true now: go")
        var fileHelper = facts
        fileHelper.place = "file"; fileHelper.placeIsFile = true
        fileHelper.placeShowing = false
        if case .wait(let why) = NoteHelp.admit(fileHelper) { expect(why.contains("document"), "a file helper with another document showing waits for its document", why) }
        else { expect(false, "a file helper with another document showing waits", "\(NoteHelp.admit(fileHelper))") }
        fileHelper.placeShowing = true
        expect(NoteHelp.admit(fileHelper) == .go, "its own document showing: go")
        var placed = facts
        placed.place = "a.example"; placed.placeShowing = false
        if case .wait = NoteHelp.admit(placed) { expect(true, "") } else { expect(false, "its place not in front: waits") }
        var access = facts
        access.sources = [("S1", "Trips")]
        access.privateBooks = []
        expect(NoteHelp.admit(access) == .go, "its sources readable: go")
        access.privateBooks = ["Trips"]
        if case .fail = NoteHelp.admit(access) { expect(true, "") } else { expect(false, "a source's notebook made private during the wait: fails") }
        access.sources = [("S1", nil)]
        if case .fail = NoteHelp.admit(access) { expect(true, "") } else { expect(false, "a source gone: fails") }
        var providerGone = facts
        providerGone.available = ["codex"]
        expect(NoteHelp.admit(providerGone) == .fail("Claude Code isn't set up in Petal."), "the pinned AI disabled while it waited: fails, never another", "\(NoteHelp.admit(providerGone))")
        var unmodelled = facts
        unmodelled.provider = "codex"; unmodelled.available = ["codex"]; unmodelled.model = "gpt-6.1-sol"; unmodelled.models = ["gpt-6"]
        if case .fail = NoteHelp.admit(unmodelled) { expect(true, "") } else { expect(false, "its pinned model gone: fails") }
        var moved = facts
        moved.notebook = "Home"
        if case .fail = NoteHelp.admit(moved) { expect(true, "") } else { expect(false, "the note moved to another notebook during the wait: fails") }
        var missing = facts
        missing.paperFound = false
        if case .fail = NoteHelp.admit(missing) { expect(true, "") } else { expect(false, "the note not one paper now: fails") }
        expect(NoteHelp.answerTarget(papers: 1, readOnly: false) == .write && NoteHelp.answerTarget(papers: 2, readOnly: true) == .hold
               && NoteHelp.answerTarget(papers: 0, readOnly: true) == .hold, "an answer at a conflict (or with the note away) is held, never dropped")
        var heldAnswer = NoteFile(id: "K1", created: now)
        heldAnswer.ink = [NoteHelp.Ink(who: "✦ Petal", text: "Kept through the conflict")]
        heldAnswer.helper = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", at: now)
        heldAnswer.watch = NoteHelp.Watch(every: "1d", line: "x", mac: "m")
        var kept = NoteFile(id: "K1", created: now, body: "The person's words")
        NoteHelp.applyAnswer(NoteFile.parse(heldAnswer.serialized(), fallbackID: "K1", fallbackDate: now), to: &kept)
        expect(kept.ink.first?.text == "Kept through the conflict" && kept.helper?.state == .done && kept.body == "The person's words" && kept.watch == nil,
               "applied to the kept paper: only the answer's keys")
        let journalDir = FileManager.default.temporaryDirectory.appending(path: "petal-helperjournal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let journalFile = journalDir.appending(path: "helper-answers.json")
        let firstHeld = HelperJournal.Entry(noteID: "K1", answer: heldAnswer.serialized(), at: now)
        let newer = HelperJournal.Entry(noteID: "K1", answer: heldAnswer.serialized() + "\n", at: now.addingTimeInterval(1))
        let other = HelperJournal.Entry(noteID: "K2", answer: "x", at: now)
        let entries = HelperJournal.adding(newer, to: HelperJournal.adding(other, to: [firstHeld]))
        expect(entries.count == 2 && entries.contains(newer) && !entries.contains(firstHeld), "a newer answer for a note replaces the one held")
        expect(HelperJournal.save(entries, to: journalFile) && HelperJournal.load(journalFile) == entries, "the helpers' journal survives a quit (read back from disk)")
        expect(NoteHelp.followUpTarget(runCheckout: nil, runProvider: "claude", runModel: "", words: "and have GPT 6.1 Sol look for holes", home: "/u") == .review,
               "a named reviewer is its own request, never steering the current agent")
        let bounds = NoteHelp.paperHeights(screen: 700, chrome: 110, editor: 490, ink: 5000, controls: 150)
        expect(bounds.editor + bounds.ink + 110 + 150 <= 700 && bounds.ink > 0, "the open paper fits the screen, controls kept outside the scroll", "\(bounds)")
        let small = NoteHelp.paperHeights(screen: 900, chrome: 110, editor: 200, ink: 60, controls: 150)
        expect(small.editor == 200 && small.ink == 60, "what fits isn't cut")
        let tiny = NoteHelp.paperHeights(screen: 300, chrome: 110, editor: 490, ink: 400, controls: 150)
        expect(tiny.editor + tiny.ink <= 300 - 110 - 150 + 80 && tiny.ink >= 0, "even on a short screen the controls keep their room", "\(tiny)")
        let oldTurn = RunToken(), newRun = RunToken()
        expect(NoteHelp.completionMatches(turn: newRun, run: newRun) && !NoteHelp.completionMatches(turn: oldTurn, run: newRun) && !NoteHelp.completionMatches(turn: nil, run: newRun),
               "a completion belongs to the run whose token started that turn")

        // MARK: Round eight: privacy at the gate, tool outcomes, re-sticks, forms

        var madePrivate = facts
        madePrivate.placePrivate = true
        if case .fail = NoteHelp.admit(madePrivate) { expect(true, "") } else { expect(false, "its place's app made private while queued: the run fails") }
        var privacyChanged = facts
        privacyChanged.builtPrivacy = 3; privacyChanged.nowPrivacy = 4
        expect(NoteHelp.admit(privacyChanged) == .rebuild, "another app made private since it was told: what it's told is made again", "\(NoteHelp.admit(privacyChanged))")
        privacyChanged.builtPrivacy = 4
        expect(NoteHelp.admit(privacyChanged) == .go, "told under the current private apps: go")
        expect(NoteHelp.toolOutcome(.go) == .answer && NoteHelp.toolOutcome(.wait("its window")) == .park("its window")
               && NoteHelp.toolOutcome(.fail("gone")) == .fail("gone") && NoteHelp.toolOutcome(.rebuild) == .rebuild,
               "a tool's admission changes the run: waiting parks it, failing fails it, never only words back")
        var windowA = NoteStick(kind: .window); windowA.title = "Window A"
        var talk = NoteStick(kind: .file); talk.path = "/Users/someone/Talk.key"
        let onWindow = NoteHelp.requirement([windowA], here: 0)
        expect(onWindow == windowA, "placed on its window: that window is required")
        let restuck = NoteHelp.requirement([talk], here: nil)
        expect(restuck == talk, "re-stuck to a file while running: the file's place is required", "\(String(describing: restuck))")
        var talkElsewhere = talk
        talkElsewhere.fileID = "mac-1|VOL|9|9"
        var talkRecorded = talk
        talkRecorded.fileID = "mac-1|VOL|41|1000"
        expect(restuck.map { !$0.samePlace(talkElsewhere) || talkElsewhere.fileID.isEmpty } == true && !talkRecorded.samePlace(talkElsewhere),
               "the same path with another file behind it is another place (samePlace goes by the file, never the path)")
        let deskOnly = NoteHelp.requirement([NoteStick(kind: .desktop)], here: 0)
        expect(deskOnly == nil, "re-stuck to the Desktop only: nothing in an app is required")
        for screen in [300.0, 500.0, 900.0] as [CGFloat] {
            let room = NoteHelp.formRoom(screen: screen, chrome: 230, actions: 44)
            expect(room >= 60 && (screen < 334 || room + 230 + 44 <= screen), "a form's fields scroll; its buttons stay on the screen (\(screen))", "\(room)")
        }

        // MARK: Rounds nine to eleven: second opinions add to the complete ink, runnable lines, the helper cover rule, a bare @Petal

        let primaryInk = NoteHelp.Ink(who: "✦ Petal · Codex", text: "Fixed it.", proof: ["tests pass"], link: "https://github.com/o/r/pull/7", code: true)
        let objectionsInk = NoteHelp.Ink(who: "GPT 6.1 Sol", text: "1. Is the week view covered?", objections: 1)
        // A second opinion's result is only its own opinion, applied onto the note's ink as it is when it lands.
        let reviewedHash = NoteHelp.inkHash(primaryInk)
        let apply = { (result: NoteHelp.Result, onto: [NoteHelp.Ink]) -> [NoteHelp.Ink] in
            var file = NoteFile(id: "OP0", created: now)
            file.ink = onto
            result.apply(to: &file)
            return file.ink
        }
        let added = apply(NoteHelp.Result(opinion: objectionsInk, reviewed: reviewedHash, helper: .keep), [primaryInk])
        expect(added.count == 2 && added[0] == primaryInk && added[1].opinion && added[1].objections == 1 && added[1].reviewed == reviewedHash,
               "a second opinion's objections are added after the primary on the note (its ink, PR link, proof), with the answer it reviewed", "\(added)")
        let failed = apply(NoteHelp.Result(opinion: NoteHelp.Ink(who: "GPT 6.1 Sol", text: "No second opinion: Codex isn't set up in Petal.", link: NoteHelp.settingsInk),
                                           reviewed: reviewedHash, helper: .keep), [primaryInk])
        expect(failed.count == 2 && failed[0] == primaryInk && failed[1].opinion && failed[1].link == NoteHelp.settingsLink,
               "a second opinion that fails (not set up, sign-in, launch) is added too, never in the primary's place")
        let heldInk = [primaryInk, NoteHelp.Ink(who: "Opus 5.5", text: "1. One more?", objections: 1)]
        let again = apply(NoteHelp.Result(opinion: NoteHelp.Ink(who: "GPT 6.1 Sol", text: "No objections.", objections: 0), reviewed: reviewedHash, helper: .keep), heldInk)
        expect(again.count == 3 && again[0] == primaryInk && again[1].who == "Opus 5.5" && again[2].objections == 0,
               "on the note's ink as it is: the primary and another reviewer's opinion stay", "\(again)")
        let redo = apply(NoteHelp.Result(opinion: NoteHelp.Ink(who: "Opus 5.5", text: "No objections.", objections: 0), reviewed: reviewedHash, helper: .keep), heldInk)
        expect(redo.count == 2 && redo[0] == primaryInk && redo[1].objections == 0, "the same reviewer again replaces only its own opinion")
        let turn = apply(NoteHelp.Result(opinion: NoteHelp.Ink(who: "GPT 6.1 Sol", text: "Looking at the week view next."), reviewed: reviewedHash, helper: .keep),
                         heldInk + [objectionsInk])
        expect(turn.count == 3 && turn[0] == primaryInk && turn[1].who == "Opus 5.5" && turn[2].text.hasPrefix("Looking"),
               "a reviewer's turn on the way replaces only its own earlier opinion")
        var opinionFile = NoteFile(id: "OP1", created: now)
        opinionFile.ink = failed
        let opinionBack = NoteFile.parse(opinionFile.serialized(), fallbackID: "OP1", fallbackDate: now).ink
        expect(opinionBack == failed, "a failed opinion stays an opinion through the front matter", "\(opinionBack)")

        // Which lines an edit touches, and which may get a mark that runs (checked on a real editor in NoteRichCheck).
        let typedText = "intro\n@Petal summarize this page\nmore"
        let at = ("intro\n@Petal summarize this pag" as NSString).length
        let lineRange = NSRange(location: 6, length: ("@Petal summarize this page" as NSString).length)
        let typedLines = NoteHelp.editedLines(after: typedText, location: at, inserted: "e", person: true)
        expect(typedLines.count == 1 && typedLines[0].range == lineRange && typedLines[0].marks, "typing a character marks its line")
        let returnedText = "intro\n@Petal summarize this page\n\nmore"
        let end = ("intro\n@Petal summarize this page" as NSString).length
        expect(NoteHelp.editedLines(after: returnedText, location: end, inserted: "\n", person: true).isEmpty, "the person's Return at the end of a line touches nothing")
        let undoneReturn = NoteHelp.editedLines(after: returnedText, location: end, inserted: "\n", person: false)
        expect(undoneReturn.contains { $0.range == lineRange } && undoneReturn.allSatisfy { !$0.marks },
               "undo or redo putting a line break back clears the line before it too, and marks nothing", "\(undoneReturn)")
        let joined = "intro\n@Petal summarize this page"
        let joinedLines = NoteHelp.editedLines(after: joined, location: end, inserted: "", person: true)
        expect(joinedLines.contains { $0.range == lineRange } && joinedLines.allSatisfy { !$0.marks },
               "Backspace joining a blank line onto an answered line clears it and marks nothing (deleting isn't writing)", "\(joinedLines)")
        let deletedChar = NoteHelp.editedLines(after: "intro\n@Petal summarize this pag\nmore", location: at, inserted: "", person: true)
        expect(deletedChar.count == 1 && !deletedChar[0].marks, "a deletion clears its line without marking it")
        let split = "intro\n@Petal summarize\n this page"
        let splitLines = NoteHelp.editedLines(after: split, location: ("intro\n@Petal summarize" as NSString).length, inserted: "\n", person: true)
        expect(splitLines.count == 2 && splitLines.allSatisfy { !$0.marks }, "Return inside a line clears both halves (no characters written)")
        let pasted = NoteHelp.editedLines(after: "intro\n@Petal one\n@Petal two", location: 5, inserted: "\n@Petal one\n@Petal two", person: true)
        expect(pasted.filter(\.marks).count == 2, "a paste marks the lines its characters land on")

        // A second opinion's checkout: the work it reviews, chosen as a primary request's is.
        expect(NoteHelp.reviewCheckout(current: "/u/checkout-a", words: "@Petal have GPT 6.1 Sol look for holes", home: "/u") == .join, "no checkout named: it joins the work")
        expect(NoteHelp.reviewCheckout(current: "/u/checkout-a", words: "@Petal have GPT 6.1 Sol look for holes in ~/checkout-a", home: "/u") == .join, "the work's own checkout: it joins")
        expect(NoteHelp.reviewCheckout(current: "/u/checkout-a", words: "@Petal have GPT 6.1 Sol look for holes in ~/checkout-b", home: "/u") == .refuse("/u/checkout-b"),
               "another checkout is refused, never reviewed in the run's worktree")
        expect(NoteHelp.reviewCheckout(current: nil, words: "@Petal have GPT 6.1 Sol look for holes in ~/checkout-b", home: "/u") == .refuse("/u/checkout-b"),
               "work in no checkout: a named one is refused")
        var reviewQueue = FollowUpQueue<String>()
        let reviewed = RunToken()
        let sol = NoteHelp.models("GPT 6.1 Sol look for holes").first { $0.holes }!
        reviewQueue.addReview(sol, asked: "@Petal have GPT 6.1 Sol look for holes", note: "N1", token: reviewed, line: "reviewer line")
        reviewQueue.clear(reviewed)
        expect(reviewQueue.takeDropped() == ["reviewer line"], "a review asked of a run that's stopped gives its line back (it can run again)")
        reviewQueue.addReview(sol, asked: "first", note: "N1", token: reviewed, line: "older review")
        reviewQueue.addReview(sol, asked: "second", note: "N1", token: reviewed, line: "newer review")
        let taken = reviewQueue.review(note: "N1", current: reviewed)
        expect(taken?.asked == "second" && taken?.line == "newer review" && reviewQueue.takeDropped() == ["older review"],
               "once the run succeeds, the latest review runs holding its line; an earlier one's line is given back")
        reviewQueue.addReview(sol, asked: "x", note: "N1", token: reviewed, line: "said meanwhile")
        expect(reviewQueue.next(note: "N1", current: reviewed) == nil, "a queued review is never sent to the run as a turn")

        var followQueue = FollowUpQueue<String>()
        let followToken = RunToken()
        followQueue.add("go on", note: "N1", token: followToken, line: "second line")
        let sent = followQueue.next(note: "N1", current: followToken)
        expect(sent?.line == "second line", "a follow-up's line goes with it when it's sent (the run holds it until that turn succeeds)")
        followQueue.add("and this", note: "N1", token: followToken, line: "third line")
        followQueue.clear(followToken)
        let dropped = followQueue.takeDropped()
        expect(dropped == ["third line"], "a follow-up that never ran gives its own line back (runnable again)")
        var helperFile = NoteFile(id: "HC1", created: now)
        helperFile.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: "Reading", at: now)
        NoteHelp.HelperChange.keep.apply(to: &helperFile)
        expect(helperFile.helper?.state == .working, "a turn on the way keeps the helper line")
        NoteHelp.HelperChange.clear.apply(to: &helperFile)
        let clearedBack = NoteFile.parse(helperFile.serialized(), fallbackID: "HC1", fallbackDate: now)
        expect(helperFile.helper == nil && clearedBack.helper == nil, "Stop clears the working line, also on disk (nothing says it's at work after a restart)")
        NoteHelp.HelperChange.set(NoteHelp.Helper(state: .failed, who: "✦ Petal", step: "x", at: now)).apply(to: &helperFile)
        expect(helperFile.helper?.state == .failed, "a failure sets it")

        // Control requests are done on the note, also while a helper works: never a follow-up.
        for (words, control) in [("@Petal stop watching", true), ("@Petal pause", true), ("@Petal remember the side door", true),
                                 ("@Petal forget the side door", true), ("@Petal bring this back Friday", true), ("@Petal put this away", true),
                                 ("@Petal stop the morning notes", true), ("@Petal what about the side door?", false), ("@Petal recalculate", false)] {
            expect(NoteHelp.isControl(NoteHelp.request(words, now: now)) == control, "“\(words)” is \(control ? "" : "not ")a control request")
        }
        expect(NoteHelp.request("@Petal pause", now: now) == .pause, "pause is said in words too")

        // Quick calls: a named AI is checked (not set up: fails, never another), and the gate admits it when it starts.
        expect(NoteHelp.providerChoice(named: .codex, available: ["claude"], chat: "claude") == .missing("Codex"), "a quick call naming Codex without it: not set up")
        var quickFacts = NoteHelp.GateFacts()
        quickFacts.provider = "codex"; quickFacts.available = ["claude"]
        if case .fail = NoteHelp.admit(quickFacts) { expect(true, "") } else { expect(false, "a queued quick call whose AI went away fails when it starts") }
        quickFacts.available = ["claude", "codex"]
        expect(NoteHelp.admit(quickFacts) == .go, "its AI there when it starts: it goes")

        // A second opinion in a saved worktree: only where this note's worktree of its saved checkout belongs.
        let savedTree = NoteHelp.Worktree(path: "/s/Worktrees/" + NoteHelp.worktreeName(checkout: "/u/garden", noteID: "W1"), branch: "petal/fix-w1", checkout: "/u/garden", remote: "origin")
        expect(NoteHelp.reviewTreeOK(savedTree, resolvedTree: savedTree.path, canonicalCheckout: "/u/garden", noteID: "W1", worktrees: "/s/Worktrees"),
               "its own worktree, where it belongs: checked with git next")
        var movedTree = savedTree; movedTree.path = "/tmp/elsewhere"
        expect(!NoteHelp.reviewTreeOK(movedTree, resolvedTree: movedTree.path, canonicalCheckout: "/u/garden", noteID: "W1", worktrees: "/s/Worktrees"),
               "a saved path elsewhere is never trusted")
        expect(!NoteHelp.reviewTreeOK(savedTree, resolvedTree: savedTree.path, canonicalCheckout: "/u/garden", noteID: "W2", worktrees: "/s/Worktrees"),
               "another note's worktree is never this one's")
        var branchless = savedTree; branchless.branch = ""
        expect(!NoteHelp.reviewTreeOK(branchless, resolvedTree: branchless.path, canonicalCheckout: "/u/garden", noteID: "W1", worktrees: "/s/Worktrees"),
               "no stored branch: not reviewed")

        // A note's id must be lasting before a helper's run is registered for it.
        expect(!NoteShelf.lasting("file:/n/Trips/Plan.md", pending: []) && !NoteShelf.lasting("ID-1", pending: ["ID-1"]) && NoteShelf.lasting("ID-1", pending: []),
               "a hand-written note, or one whose id is still being written, waits for its id to land")

        let coverHere = NoteHelp.CoverCandidate(key: "/n/Trips/About this notebook.md", name: "About this notebook.md", inFolder: true)
        let flagged = NoteHelp.CoverCandidate(key: "/n/Trips/Plan.md", name: "Plan.md", inFolder: true)
        let nested = NoteHelp.CoverCandidate(key: "/n/Trips/Old/About this notebook.md", name: "About this notebook.md", inFolder: false)
        expect(NoteHelp.coverChoice([flagged, coverHere], unread: 0) == .one(coverHere.key), "the cover is the file named for it in the notebook's own folder")
        expect(NoteHelp.coverChoice([flagged], unread: 0) == .none && NoteHelp.coverChoice([nested], unread: 0) == .none,
               "a note saying cover: true, or a cover file elsewhere, is no cover for helpers")
        let copyCover = NoteHelp.CoverCandidate(key: "/n/Trips/About this notebook (conflicted copy).md", name: "About this notebook (conflicted copy).md", inFolder: true)
        expect(NoteHelp.coverChoice([coverHere, copyCover], unread: 0) == .conflict, "a cover with a conflict copy needs a choice first: no memory written")
        var versioned = coverHere; versioned.version = true
        expect(NoteHelp.coverChoice([coverHere, versioned], unread: 0) == .conflict, "a cover with an iCloud version needs a choice first")
        expect(NoteHelp.coverChoice([], unread: 1) == .notHere && NoteHelp.coverChoice([coverHere], unread: 1) == .notHere,
               "a cover not downloaded yet, or one beside it not read yet: not here (waited for, never skipped)")

        expect(NoteHelp.bare("@Petal") && NoteHelp.bare("@Petal   ") && NoteHelp.bare("  @petal"), "a bare @Petal asks nothing: refused before a run")
        expect(!NoteHelp.bare("@Petal summarize this") && !NoteHelp.bare("@Petal remember the door code is on the card"), "a request isn't bare")

        // MARK: Round thirteen: derived only from redacted text; follow-ups checked against any run's checkout

        let saved = "Q7m!a2Z:91"
        let savedIndex = UIMap.SecretIndex([saved])
        let fragment = "Q7m!a2Z"
        guard let ledger = NoteShield.shield(["# Trip\nFlights: 412\n\(saved)\nHotel: 300\nCode \(saved) total: 5"], index: savedIndex) else { return expect(false, "a ledger") }
        let rows = ledger[0].rows
        expect(rows.map(\.label.text) == ["Flights", "Hotel"], "the formula's inputs are read from the redacted body; a row that held a secret is left out", "\(rows.map(\.label.text))")
        let formula = NoteHelp.formulaRequest(NoteHelp.Told(body: ledger[0]))
        expect(!formula.text.contains(fragment) && !formula.text.contains("Q7m"), "no fragment of a saved secret reaches the formula prompt", formula.text)
        expect(NoteHelp.values("\(saved)\nFlights: 412").contains { $0.label == fragment }, "(parsed before redaction, the fragment would have been a label)")
        guard let spokenLines = NoteShield.shield(["@Petal check this every morning, tell me when it's under $300 \(saved)",
                                                   "@Petal when @Research is done, email \(saved) to the team",
                                                   "@Petal summarize \(saved)"], index: savedIndex) else { return expect(false, "lines") }
        let watchedLine = spokenLines[0].spoken.watch
        expect(watchedLine != nil && !(watchedLine?.line.text.contains("Q7m") ?? true), "a watcher's line is derived from the redacted words", watchedLine?.line.text ?? "nil")
        let chained = spokenLines[1].spoken.chainAsk
        expect(chained != nil && !(chained?.text.contains("Q7m") ?? true), "a chain's request is derived from the redacted words", chained?.text ?? "nil")
        expect(!spokenLines[2].spoken.text.contains("@Petal") && !spokenLines[2].spoken.text.contains("Q7m"), "the line without its @Petal, derived after redaction")
        expect(NoteHelp.followUpTarget(runCheckout: nil, runProvider: "claude", runModel: "", words: "@Petal check it in ~/checkout-b instead", home: "/u") == .newRun,
               "a run with no checkout of its own (a chat helper, a second opinion outside a worktree) never takes a path named in a follow-up")
        expect(NoteHelp.followUpTarget(runCheckout: "/u/checkout-a", runProvider: "claude", runModel: "", words: "@Petal check it in ~/checkout-b instead", home: "/u") == .newRun,
               "a reviewer keeping its verified checkout: another one named starts its own run")
        expect(NoteHelp.followUpTarget(runCheckout: "/u/checkout-a", runProvider: "claude", runModel: "", words: "@Petal and look at ~/checkout-a/README", home: "/u") == .newRun
               || NoteHelp.followUpTarget(runCheckout: "/u/checkout-a", runProvider: "claude", runModel: "", words: "@Petal check it in ~/checkout-a", home: "/u") == .same,
               "its own checkout named: it goes to the run")

        // MARK: Round fourteen: the quick queue, a watcher's own output, nameless reasons, titles after redaction

        var quick = QuickQueue<String, String>()
        let watcherLook = RunToken(), running = RunToken()
        quick.add(.init(job: "watcher look", token: watcherLook, provider: nil, gate: nil))
        quick.add(.init(job: "recalculate", token: running, provider: nil, gate: nil))
        watcherLook.pause()
        watcherLook.cancel()
        var passes = 0
        var answered: [String] = []
        func drain() {
            passes += 1
            guard passes < 10 else { return }
            let step = quick.pass { _ in .wait }
            // What a dropped call's answer does (end → halt → resume → a pass) comes after the pass, never inside it.
            for entry in step.dropped { answered.append(entry.job); drain() }
        }
        drain()
        expect(passes == 2 && answered == ["watcher look"] && quick.entries.map(\.job) == ["recalculate"],
               "a watcher cancelled while another call waits: taken out before it's answered, answered once, no recursion", "\(passes) \(answered)")
        var unready = QuickQueue<String, String>()
        unready.add(.init(job: "named", token: RunToken(), provider: "codex", gate: nil))
        unready.add(.init(job: "chat", token: RunToken(), provider: nil, gate: nil))
        let firstStep = unready.pass { named in named == "codex" ? .none : .go("claude") }
        expect(firstStep.dropped.map(\.job) == ["named"] && firstStep.start?.entry.job == "chat" && unready.isEmpty,
               "a call whose own AI isn't ready is answered nothing (out first); the next one starts")
        var answerHeld = NoteFile(id: "J1", created: now)
        answerHeld.ink = [NoteHelp.Ink(who: "✦ Petal", text: "The answer")]
        var watchHeld = NoteFile(id: "J1", created: now)
        var lookWatch = NoteHelp.Watch(every: "1d", line: "under $100", mac: "m")
        lookWatch.id = "W1"; lookWatch.last = "$95"
        watchHeld.watch = lookWatch
        let answerEntry = HelperJournal.Entry(noteID: "J1", answer: answerHeld.serialized(), at: now)
        let watchEntry = HelperJournal.Entry(noteID: "J1", answer: watchHeld.serialized(), at: now.addingTimeInterval(1), kind: .watch)
        expect(HelperJournal.adding(watchEntry, to: [answerEntry]).count == 2, "a watcher's look is its own kind in the journal: it never replaces a helper's answer")
        var paperWithHelper = NoteFile(id: "J1", created: now)
        paperWithHelper.ink = [NoteHelp.Ink(who: "✦ Petal", text: "The primary answer")]
        paperWithHelper.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: "x", at: now)
        var olderWatch = lookWatch; olderWatch.last = "$120"
        paperWithHelper.watch = olderWatch
        NoteHelp.applyAnswer(watchHeld, to: &paperWithHelper, kind: .watch)
        expect(paperWithHelper.watch?.last == "$95" && paperWithHelper.ink.first?.text == "The primary answer" && paperWithHelper.helper?.state == .working,
               "a watcher's look lands only in its watch fields: never the ink or the helper line (so never a chain)")
        var newerWatcher = olderWatch; newerWatcher.id = "W2"
        paperWithHelper.watch = newerWatcher
        NoteHelp.applyAnswer(watchHeld, to: &paperWithHelper, kind: .watch)
        expect(paperWithHelper.watch?.id == "W2" && paperWithHelper.watch?.last == "$120", "a look for an older watcher lands on nothing")
        var backOver: NoteHelp.Watch? = lookWatch
        backOver?.last = "$130"
        expect(!NoteHelp.told(&backOver, id: "W1") && backOver?.hit == false, "told after the value came back over the line: no hit kept")
        var waitsNamed = NoteHelp.GateFacts()
        waitsNamed.notebook = "Work"; waitsNamed.startNotebook = "Work"; waitsNamed.provider = "claude"; waitsNamed.available = ["claude"]
        waitsNamed.place = "Bank of Q7m!a2Z:91"; waitsNamed.placeShowing = false
        if case .wait(let why) = NoteHelp.admit(waitsNamed) { expect(!why.contains("Q7m") && !why.contains("Bank"), "a wait's reason never names the place (it goes on the note and to the AI)", why) }
        else { expect(false, "a place not in front waits") }
        waitsNamed.placeIsFile = true
        if case .wait(let why) = NoteHelp.admit(waitsNamed) {
            expect(!why.contains("Q7m") && why.contains("document") && why.contains("Petal's viewer"), "nor its file: it says its document needs to be open in Petal's viewer", why)
        } else { expect(false, "a file not showing waits") }
        // A note on a document: its helper is told the viewer showing it is its place.
        var onFile = NoteHelp.Told()
        onFile.place = "a file"
        let plainSystem = NoteHelp.system(onFile, provider: "Claude", computerUse: false, brief: "").text
        onFile.placeIsFile = true
        let fileSystem = NoteHelp.system(onFile, provider: "Claude", computerUse: false, brief: "").text
        expect(fileSystem.contains("Petal's viewer") && fileSystem.contains("petal_view") && fileSystem.contains("copies") && !plainSystem.contains("petal_view_versions"),
               "a helper on a document is told the viewer is its place, and to change it on copies first")
        guard let afterShown = NoteShield.shield(["# Research \(saved) and more\nIts words"], index: savedIndex) else { return expect(false, "after") }
        let chainBrief = NoteHelp.brief(NoteHelp.Told(after: afterShown[0]))
        expect(chainBrief.text.contains("This runs because") && !chainBrief.text.contains("Q7m"), "a chain's done note is named by a title derived after redaction", chainBrief.text)
        expect(NoteHelp.bareHint.text == "Ask Petal something after @Petal", "replies are Shielded words")

        // MARK: Round fifteen: keyword routes never destructive by themselves, exact watcher values, chains' sources

        let routes: [(String, NoteHelp.Request)] = [
            ("@Petal check whether it's done", .ask("check whether it's done")), ("@Petal don't remove the worktree", .ask("don't remove the worktree")),
            ("@Petal is it done?", .ask("is it done?")), ("@Petal if it's done, remove the worktree", .ask("if it's done, remove the worktree")),
            ("@Petal remove the worktree", .done), ("@Petal it's done", .done),
            ("@Petal stop watching", .stopWatching), ("@Petal don't stop watching", .ask("don't stop watching")),
            ("@Petal can you stop watching this", .ask("can you stop watching this")), ("@Petal no more morning notes", .stopMorning),
            ("@Petal put this away", .putAway), ("@Petal don't put this away yet", .ask("don't put this away yet")),
            ("@Petal pause", .pause), ("@Petal should I pause", .ask("should I pause"))]
        for (line, want) in routes {
            let got = NoteHelp.request(line, now: now)
            expect(got == want, "“\(line)” routes \(want)", "\(got)")
        }
        if case .bringBack = NoteHelp.request("@Petal bring this back Friday", now: now) { expect(true, "") } else { expect(false, "a plain bring back") }
        if case .ask = NoteHelp.request("@Petal should I bring this back Friday?", now: now) { expect(true, "") } else { expect(false, "a question about bringing it back goes to the helper") }
        if case .forget = NoteHelp.request("@Petal forget that the code isn't 1234", now: now) { expect(true, "") } else { expect(false, "forget is a plain imperative by how it starts") }
        if case .watch = NoteHelp.request("@Petal check this every morning, tell me if it's under $300", now: now) { expect(true, "") } else { expect(false, "a watcher's own words still make a watcher") }
        var yen = NoteHelp.Watch(every: "1d", line: "under ¥12,000", mac: "m")
        yen.id = "Y"
        var yenWatch: NoteHelp.Watch? = yen
        expect(NoteHelp.applyLook(&yenWatch, id: "Y", shown: "¥12k", amount: 11_900, hint: nil, past: NoteHelp.crossed(11_900, line: yen.line), confirmed: true, at: now) == true,
               "¥11,900 crossed under ¥12,000")
        let roundTrip = NoteFile.parse({ var f = NoteFile(id: "Y1", created: now); f.watch = yenWatch; return f.serialized() }(), fallbackID: "x", fallbackDate: now).watch
        expect(roundTrip?.amount == 11_900 && roundTrip?.last == "¥12k", "the exact value is kept beside the corner's rounded one")
        var reread = roundTrip
        expect(NoteHelp.told(&reread, id: "Y") && reread?.hit == true, "a hit kept on the exact value (the rounded ¥12k would read as not crossed)")
        expect(NoteHelp.delivered(roundTrip!, amount: 11_900, cornerShowing: true) && !NoteHelp.delivered(roundTrip!, amount: 11_900, cornerShowing: false)
               && !NoteHelp.delivered(roundTrip!, amount: 11_800, cornerShowing: true), "delivered only once a face with the corner showed that very value")
        expect(!NotePrivacy.readable(notebook: "Diary", privateBooks: ["Diary"], asker: "Work") && NotePrivacy.readable(notebook: "Diary", privateBooks: ["Diary"], asker: "Diary"),
               "a chain's predecessor in a private notebook is read only from inside it")
        var chainFacts = NoteHelp.GateFacts()
        chainFacts.notebook = "Work"; chainFacts.startNotebook = "Work"; chainFacts.provider = "claude"; chainFacts.available = ["claude"]
        chainFacts.sources = [("R1", "Diary")]
        chainFacts.privateBooks = ["Diary"]
        if case .fail = NoteHelp.admit(chainFacts) { expect(true, "") } else { expect(false, "a predecessor moved into a private notebook: the gate fails the chain's run") }

        // MARK: Round sixteen: a helper's output shielded as it arrives, one gate for local routes, kept watcher values

        let apiKey = "saved-vault-key-Q7mA2ZdF91kLpXw3RtYv"
        let keyIndex = UIMap.SecretIndex([apiKey])
        let echoed = Said(who: "Codex", text: "Fixed it. The config had ANTHROPIC_API_KEY=\(apiKey).\nProof: tests pass with \(apiKey)\nhttps://github.com/o/r/pull/9",
                          steps: ["Read .env: \(apiKey)", "Ran the tests"], form: .code, asked: "@Petal fix it. Done means \(apiKey) works")
        guard let made = NoteHelp.shielded(echoed, index: keyIndex) else { return expect(false, "shielded output") }
        var landedFile = NoteFile(id: "S1", created: now)
        landedFile.ink = [made.ink]
        landedFile.steps = made.steps.map(\.text)
        let landedText = landedFile.serialized()
        let journalEntry = HelperJournal.Entry(noteID: "S1", answer: landedText, at: now)
        let journalData = String(data: (try? JSONEncoder().encode([journalEntry])) ?? Data(), encoding: .utf8) ?? ""
        expect(!landedText.contains("Q7mA2Zd") && !journalData.contains("Q7mA2Zd") && made.ink.proof.allSatisfy { !$0.contains("Q7mA2Zd") } && !made.ink.finish.contains("Q7mA2Zd"),
               "an answer echoing a saved key lands redacted in its ink, its proof, its finish line, on the back and in the journal", landedText)
        expect(made.ink.link == "https://github.com/o/r/pull/9" && made.ink.code, "its PR link and proof derived from the shielded words")
        expect(NoteHelp.shielded(echoed, index: .unavailable) == nil, "the vault unreadable: nothing is written (it waits, unshown)")
        let rulesGrant16 = NoteHelp.rulesGrant(["Bash(curl -H 'x-api-key: \(apiKey)')"], note: "S1", run: "R1")
        expect(!rulesGrant16.contains("curl") && !rulesGrant16.contains("Q7m") && NoteHelp.Stamp(label: "x", grant: rulesGrant16, mac: "m").parsed == .rules(rulesGrant16),
               "a stamp keeps an opaque id for the rules allowed, never the rules")
        let gated: [(String, Bool)] = [
            ("@Petal don't leave me a note every morning", false), ("@Petal leave me a note every morning", true),
            ("@Petal can you check this every morning, tell me if it's under $300", false), ("@Petal check this every morning, tell me if it's under $300", true),
            ("@Petal when @Research is done, don't draft @Proposal", false), ("@Petal when @Research is done, draft @Proposal", true),
            ("@Petal should I bring this back Friday", false), ("@Petal don't keep this calculated", false), ("@Petal keep this calculated", true),
            ("@Petal remember the code isn't 1234", true)]
        for (line, local) in gated {
            let got = NoteHelp.request(line, now: now)
            let isAsk: Bool = if case .ask = got { true } else { false }
            expect(isAsk == !local, "“\(line)” \(local ? "is" : "isn't") a local route (one gate for all of them)", "\(got)")
        }
        var kept16: NoteHelp.Watch? = { var w = NoteHelp.Watch(every: "1d", line: "under $100", mac: "m"); w.id = "K"; w.last = "$120"; w.amount = 120; return w }()
        _ = NoteHelp.applyLook(&kept16, id: "K", shown: "$90", amount: 90, hint: nil, past: true, confirmed: false, verdict: .refuted, at: now)
        expect(kept16?.last == "$120" && kept16?.amount == 120 && kept16?.unconfirmed == "", "a refuted reading never becomes the shown value")
        _ = NoteHelp.applyLook(&kept16, id: "K", shown: "$90", amount: 90, hint: nil, past: true, confirmed: false, verdict: .unconfirmed, at: now)
        expect(kept16?.last == "$120" && kept16?.amount == 120 && kept16?.unconfirmed == "$90", "an unconfirmed crossing keeps the last accepted value; its number shown faintly, couldn't confirm")
        _ = NoteHelp.applyLook(&kept16, id: "K", shown: "$110", amount: 110, hint: nil, past: false, confirmed: false, verdict: .plain, at: now)
        expect(kept16?.last == "$110" && kept16?.unconfirmed == "", "the next accepted reading clears it")
        let exact: Shielded = "\(11_899.5) and \(11_900.0)"
        expect(exact.text == "11899.5 and 11900", "a watcher's value goes on exactly, never rounded before a decision", exact.text)
        let downloading = NoteHelp.CoverCandidate(key: "/n/T/About this notebook.md", name: "About this notebook.md", inFolder: true)
        expect(NoteHelp.coverChoice([downloading], unread: 1) == .notHere && NoteHelp.coverChoice([], unread: 0) == .none,
               "a cover that can't be read yet is told apart from no cover (waited for, never skipped)")

        // MARK: After round sixteen: completion is "accepted and shown"; watchers with no AI

        var heldQueue = FollowUpQueue<String>()
        let heldRun = RunToken()
        heldQueue.addReview(sol, asked: "@Petal have GPT 6.1 Sol look for holes", note: "N1", token: heldRun, line: "review line")
        // Its answer waits for the vault: the run isn't complete, nothing asked of it is settled.
        expect(heldQueue.entries.count == 1 && heldRun.admits, "an answer waiting for the vault: the run isn't complete, its queued review waits with it")
        let shownSettled = heldQueue.settle(note: "N1", token: heldRun, succeeded: true)
        expect(shownSettled.review?.line == "review line" && shownSettled.dropped.isEmpty && heldQueue.entries.isEmpty,
               "once shown, it completes like any run: the queued review starts, holding its own line")
        let failingRun = RunToken()
        heldQueue.addReview(sol, asked: "@Petal have GPT 6.1 Sol look for holes", note: "N1", token: failingRun, line: "review line")
        let failedSettled = heldQueue.settle(note: "N1", token: failingRun, succeeded: false)
        expect(failedSettled.review == nil && failedSettled.dropped == ["review line"], "that run fails instead: the review's line is runnable again")
        var noAI: NoteHelp.Watch? = { var w = NoteHelp.Watch(every: "1d", line: "under $100", mac: "m"); w.id = "N"; return w }()
        let quiet = NoteHelp.watchVerdict(crossed: false, alreadyHit: false, confirmation: nil, asked: false)
        expect(NoteHelp.applyLook(&noAI, id: "N", shown: "$130", amount: 130, hint: nil, past: false, confirmed: false, verdict: quiet, at: now) == false
               && noAI?.last == "$130" && noAI?.unconfirmed == "", "no AI set up: a reading that doesn't cross the line updates the corner as usual")
        let unsure = NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: nil, asked: false)
        expect(NoteHelp.applyLook(&noAI, id: "N", shown: "$95", amount: 95, hint: nil, past: true, confirmed: false, verdict: unsure, at: now) == false
               && noAI?.last == "$130" && noAI?.unconfirmed == "$95" && noAI?.hit == false,
               "no AI: a crossing shows its number faintly, couldn't confirm, never a hit (so it never opens the note)")

        // MARK: Round seventeen: fail, don't hold; steps shielded at the boundary; a first unconfirmed reading

        let stepKey = "saved-vault-key-Zr81LmQx55vNpTt2Wq"
        let stepIndex = UIMap.SecretIndex([stepKey])
        guard let stepShown = NoteShield.shield(["Reading .env: ANTHROPIC_API_KEY=\(stepKey)"], index: stepIndex)?.first else { return expect(false, "a step") }
        var stepFile = NoteFile(id: "ST1", created: now)
        stepFile.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: stepShown.text, at: now)
        guard let stepMade = NoteHelp.shielded(Said(who: "✦ Petal", text: "Done.", steps: ["Reading .env: ANTHROPIC_API_KEY=\(stepKey)"]), index: stepIndex) else { return expect(false, "steps") }
        stepFile.steps = stepMade.steps.map(\.text)
        expect(!stepShown.text.contains("Zr81LmQx") && !stepFile.serialized().contains("Zr81LmQx"),
               "a step echoing a saved key is redacted where the bar, the previews (the agent's Shielded activity), the back and the file read it", stepFile.serialized())
        expect(NoteShield.shield(["a step"], index: .unavailable) == nil && NoteHelp.shielded(Said(who: "x", text: "y"), index: .unavailable) == nil,
               "the vault unreadable: nothing can be shielded, so a run can't start and output arriving fails it (nothing held)")
        let firstUnsure: NoteHelp.Watch = { var w = NoteHelp.Watch(every: "1d", line: "under $100", mac: "m"); w.unconfirmed = "$95"; return w }()
        let corner = NoteHelp.corner(firstUnsure)
        expect(corner != nil && corner?.number == nil && corner?.faint == "$95 · couldn't confirm",
               "a first reading that couldn't be confirmed: the corner is drawn, its number faint, “· couldn't confirm”")
        expect(NoteHelp.corner(NoteHelp.Watch(every: "1d", line: "under $100", mac: "m")) == nil, "nothing read yet: no corner")

        // MARK: Open all never launches an app or a script (NoteTasks)

        let scratch = FileManager.default.temporaryDirectory.appending(path: "petal-notetasks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let write = { (name: String, text: String) -> URL in
            let url = scratch.appending(path: name)
            try? Data(text.utf8).write(to: url)
            return url
        }
        let pdf = write("Quote.pdf", "%PDF-1.4\n%%EOF\n")
        let png = write("Shot.png", "png")
        let plainText = write("Notes.txt", "words")
        let script = write("run.sh", "#!/bin/sh\necho hi\n")
        let command = write("Start.command", "#!/bin/sh\necho hi\n")
        let workflow = write("Do.workflow", "x")
        let webloc = write("Site.webloc", "<plist/>")
        let fileloc = write("Elsewhere.fileloc", "<plist/>")
        let dmg = write("Disk.dmg", "x")
        let pkg = write("Install.pkg", "x")
        let app = scratch.appending(path: "Fake.app")
        try? FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let folder = scratch.appending(path: "Folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let linkToScript = scratch.appending(path: "Looks fine.pdf")
        try? FileManager.default.createSymbolicLink(at: linkToScript, withDestinationURL: script)
        let aliasToScript = scratch.appending(path: "Alias to script")
        if let mark = try? script.bookmarkData(options: .suitableForBookmarkFile) { try? URL.writeBookmarkData(mark, to: aliasToScript) }
        let aliasToPDF = scratch.appending(path: "Alias to quote")
        if let mark = try? pdf.bookmarkData(options: .suitableForBookmarkFile) { try? URL.writeBookmarkData(mark, to: aliasToPDF) }
        // The one opener's file rule (NoteTasks.decide, what Open all does in the note and in the Petal Notes window).
        let fileAction = { (url: URL) -> NoteTasks.FileAction in NoteTasks.decide(url).1 }
        let real = { (url: URL) in url.resolvingSymlinksInPath() }
        expect(fileAction(pdf) == .open && fileAction(png) == .open && fileAction(plainText) == .open, "a PDF, a picture, text: opened")
        for blocked in [script, command, workflow, webloc, fileloc, dmg, pkg, app, folder] {
            expect(fileAction(blocked) == .reveal, "never opened, only revealed: \(blocked.lastPathComponent)", "\(fileAction(blocked))")
        }
        expect(fileAction(linkToScript) == .reveal && NoteTasks.decide(linkToScript).0.path == real(script).path, "a link named like a PDF that leads to a script: resolved first, revealed",
               "\(NoteTasks.decide(linkToScript))")
        expect(fileAction(aliasToScript) == .reveal, "a Finder alias to a script: resolved first, revealed", "\(NoteTasks.decide(aliasToScript))")
        expect(fileAction(aliasToPDF) == .open && NoteTasks.decide(aliasToPDF).0.path == real(pdf).path, "an alias to a PDF: the PDF is opened", "\(NoteTasks.decide(aliasToPDF))")
        let part = { (kind: String, target: String) in NoteContract.TaskItem(kind: kind, title: "", target: target) }
        expect(fileAction(scratch.appending(path: "gone.pdf")) == .reveal && NoteTasks.url(part("file", "relative/path.pdf")) == nil
               && NoteTasks.located(part("file", scratch.appending(path: "gone.pdf").path), mac: "m", follow: { _ in nil }) == nil,
               "a file that isn't there is never opened (nor found); a relative path is no file")
        let tab = { (target: String) in NoteTasks.url(part("tab", target)) }
        expect(tab("https://a.example/x") == URL(string: "https://a.example/x")! && tab("http://a.example") != nil, "tabs: http and https")
        expect(tab("file:///Applications/Calculator.app") == nil && tab("javascript:alert(1)") == nil && tab("vnc://host") == nil && tab("ssh://host") == nil,
               "tabs: nothing else")
        let mail = { (target: String) in NoteTasks.url(part("mail", target)) }
        expect(mail("message://%3Cabc%40example.com%3E") != nil && mail("mailto:a@example.com") == nil && mail("https://a.example") == nil, "mail: by its message address only")
        expect(NoteTasks.url(part("window", "com.example.app")) == nil, "a window never launches its app")
        expect(NoteTasks.web("https://github.com/a/b/pull/1") != nil && NoteTasks.web("file:///etc/hosts") == nil && NoteTasks.web("x-man-page://ls") == nil,
               "a helper's link: http or https only")

        // MARK: Round eighteen: one launch order, one result, pause ends app actions, ordinary chats never wait

        // A. `NoteHelp.launch`, the order `NoteHelpers.prepare` runs every paid call's launch through. What waits is
        // the call's sources; its words are made last, only when every step before passed.
        final class LaunchWorld {
            var vaultReadable = true
            var cover: NoteHelp.Gathered<String> = .read("the note as it is now")
            var gate: NoteHelp.Admission = .go
            var live: NoteHelp.Live = .running
            /// The vault changes while the words are shielded, this many times.
            var changes = 0
            var asked: [String] = []
            var built: [String] = []
        }
        let world = LaunchWorld()
        let launchSteps = NoteHelp.LaunchSteps<String, String, String>(
            live: { world.live },
            vault: { ready in world.asked.append("vault"); ready(world.vaultReadable) },
            sources: { read in world.asked.append("sources"); read(world.cover) },
            gate: { world.asked.append("gate"); return world.gate },
            build: { raw, done in
                world.asked.append("build")
                let current = world.changes == 0
                if !current { world.changes -= 1 }
                world.built.append(raw)
                done("shielded: " + raw, current)
            },
            words: { $0.isEmpty ? nil : "prompt from " + $0 })
        var launched: NoteHelp.Launched<String, String>?
        let launchNow = { launched = nil; world.asked = []; NoteHelp.launch(launchSteps) { launched = $0 } }
        launchNow()
        if case .go(let words, let told)? = launched {
            expect(words == "prompt from shielded: the note as it is now" && told == "shielded: the note as it is now" && world.asked == ["vault", "sources", "gate", "build"],
                   "a launch: the vault, the sources and cover, the gate, then the words, in that order", "\(world.asked)")
        } else { expect(false, "a launch goes", "\(String(describing: launched))") }
        // A run that waited (for room, its gate, Go on) holds only its sources. The vault becomes unreadable before it
        // launches: refused at the first step, and its prompt was never built.
        world.built = []
        world.vaultReadable = false
        launchNow()
        if case .vaultUnreadable? = launched { expect(world.asked == ["vault"] && world.built.isEmpty, "the vault unreadable before launch: refused, no source read, no prompt built", "\(world.asked)") }
        else { expect(false, "the vault unreadable before launch is refused", "\(String(describing: launched))") }
        world.vaultReadable = true
        // Its sources changed while it waited: the words are made from them as they are at launch.
        world.cover = .read("the note, edited while it waited")
        launchNow()
        if case .go(let words, _)? = launched { expect(words.hasSuffix("edited while it waited"), "what waited is the sources: the prompt is made from them as they are at launch") }
        else { expect(false, "a waiting call launches from its sources as they are then") }
        // A secret saved while the words were being shielded: those words are thrown away and everything is done again.
        world.built = []
        world.changes = 1
        launchNow()
        if case .go? = launched {
            expect(world.asked == ["vault", "sources", "gate", "build", "vault", "sources", "gate", "build"] && world.built.count == 2,
                   "the vault changed under the words: made again from the start, never sent as they were", "\(world.asked)")
        } else { expect(false, "words made under a vault that changed are made again") }
        world.changes = 9
        launchNow()
        if case .vaultUnreadable? = launched { expect(true, "a vault that keeps changing: refused") } else { expect(false, "a vault that keeps changing is refused, never sent") }
        world.changes = 0
        // Recalculate with a cover that can't be read: step 2 refuses, and nothing after it is asked (it doesn't start).
        expect(NoteHelp.coverChoice([], unread: 1) == .notHere, "a cover there but not readable yet isn't no cover")
        world.cover = .refused
        world.built = []
        launchNow()
        if case .refused? = launched { expect(world.asked == ["vault", "sources"] && world.built.isEmpty, "an unreadable cover: the call doesn't start (no gate, no prompt)", "\(world.asked)") }
        else { expect(false, "an unreadable cover refuses the launch") }
        world.cover = .read("the note as it is now")
        // The gate, from what's true at launch: a refusal, a wait and a rebuild all come before any words.
        for (gate, name) in [(NoteHelp.Admission.fail("A note it was checking against is private now."), "fail"), (.wait("Waiting for this note's place to be in front."), "wait"), (.rebuild, "rebuild")] {
            world.gate = gate
            world.built = []
            launchNow()
            let stopped: Bool
            switch launched {
            case .failed?: stopped = name == "fail"
            case .wait?: stopped = name == "wait"
            case .rebuild?: stopped = name == "rebuild"
            default: stopped = false
            }
            expect(stopped && world.asked == ["vault", "sources", "gate"] && world.built.isEmpty, "the gate says \(name): nothing is built", "\(world.asked)")
        }
        world.gate = .go
        world.live = .paused
        launchNow()
        if case .paused? = launched { expect(world.asked.isEmpty, "paused: it waits as it was, nothing asked, nothing built") } else { expect(false, "a paused run's call waits") }
        world.live = .gone
        launchNow()
        if case .gone? = launched { expect(world.asked.isEmpty, "its run ended: nothing") } else { expect(false, "an ended run launches nothing") }
        // A follow-up waits as the person wrote it (a raw line), never as shielded words.
        var rawQueue = FollowUpQueue<String>()
        let rawToken = RunToken()
        rawQueue.add("@Petal and the saved-vault-key-12345 too", note: "N", token: rawToken)
        let waitingLine: String? = rawQueue.next(note: "N", current: rawToken)?.text
        expect(waitingLine == "@Petal and the saved-vault-key-12345 too", "a follow-up waits as the person's line (shielded only when its turn starts)")

        // B. One result. A recalculation whose note went into conflict: its formula and `done` are one journal entry,
        // held whole, and land in one change (or not at all); nothing says "done" without the formula.
        let doneLine = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", asked: "@Petal make this recalculate", mac: "m", at: now)
        let recalculated = NoteHelp.Result(answer: nil, calc: NoteHelp.Calc(label: "Total", formula: "sum()"), helper: .set(doneLine))
        let journaled = HelperJournal.adding(recalculated, note: "RC1", notebook: "Inbox", sources: [], at: now, to: [])
        expect(journaled.count == 1 && journaled[0].of == .answer, "a run's result is one journal entry")
        expect(NoteHelp.answerTarget(papers: 2, readOnly: true) == .hold, "its note in conflict: the entry is held, nothing of it written")
        var conflicted = NoteFile(id: "RC1", created: now)
        conflicted.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: "Working out the formula", at: now)
        expect(conflicted.calc == nil && conflicted.helper?.state == .working, "while it's held the note says neither done nor a formula")
        NoteHelp.applyAnswer(NoteFile.parse(journaled[0].answer, fallbackID: "RC1", fallbackDate: now), to: &conflicted)
        expect(conflicted.calc?.formula == "sum()" && conflicted.helper?.state == .done, "kept: the formula and done land together, in one change")
        let putAwayResult = NoteHelp.Result(answer: NoteHelp.Ink(who: "✦ Petal · put away today", text: "Put away: 2 tabs."),
                                            task: [NoteHelp.TaskItem(kind: .tab, title: "Docs", target: "https://example.com/docs")], helper: .set(doneLine))
        var away = NoteFile(id: "PA1", created: now)
        putAwayResult.apply(to: &away)
        expect(away.task.count == 1 && away.ink.count == 1 && away.helper?.state == .done, "a task put away is part of the same result as its line and done")
        let resultBack = NoteHelp.Result(held: NoteFile.parse(putAwayResult.held(noteID: "PA1").serialized(), fallbackID: "PA1", fallbackDate: now))
        expect(resultBack == putAwayResult, "a result reads back from the journal exactly", "\(resultBack)")
        // Two results for one note are one entry: what landing each in turn would leave; one being written is left alone.
        let answerInk = NoteHelp.Ink(who: "✦ Petal", text: "It's the 14th.")
        let firstResult = NoteHelp.Result(answer: answerInk, steps: ["Looking at the page"], helper: .keep)
        let opinionInk = NoteHelp.Ink(who: "GPT 6.1 Sol", text: "1. Which month?", objections: 1)
        let opinionResult = NoteHelp.Result(opinion: opinionInk, reviewed: NoteHelp.inkHash(answerInk), steps: ["Reading the note"], helper: .set(doneLine))
        var oneByOne = NoteFile(id: "TW1", created: now), together = NoteFile(id: "TW1", created: now)
        firstResult.apply(to: &oneByOne)
        opinionResult.apply(to: &oneByOne)
        firstResult.then(opinionResult).apply(to: &together)
        expect(oneByOne.serialized() == together.serialized() && together.ink.count == 2 && together.steps == ["Looking at the page", "GPT 6.1 Sol: Reading the note"],
               "two results held for one note compose into what landing each in turn leaves", together.serialized())
        let heldFirst = HelperJournal.adding(firstResult, note: "TW1", notebook: "Inbox", sources: ["S1"], at: now, to: [])
        let bothHeld = HelperJournal.adding(opinionResult, note: "TW1", notebook: "Inbox", sources: ["S2"], at: now.addingTimeInterval(1), to: heldFirst)
        expect(bothHeld.count == 1 && bothHeld[0].sources == ["S1", "S2"], "held together as one entry, with every note either read", "\(bothHeld.map(\.sources))")
        let inFlight = HelperJournal.adding(opinionResult, note: "TW1", notebook: "Inbox", sources: [], at: now.addingTimeInterval(1), to: heldFirst, busy: [heldFirst[0].at])
        expect(inFlight.count == 2 && inFlight[0] == heldFirst[0], "one being written now is left to land; the next goes after it")
        // An entry an earlier Petal kept (the note's whole answer) still lands.
        var legacy = NoteFile(id: "LG1", created: now)
        legacy.ink = [answerInk, { var ink = opinionInk; ink.opinion = true; return ink }()]
        legacy.helper = doneLine
        var legacyTarget = NoteFile(id: "LG1", created: now)
        NoteHelp.applyAnswer(NoteFile.parse(legacy.serialized(), fallbackID: "LG1", fallbackDate: now), to: &legacyTarget)
        expect(legacyTarget.ink.count == 2 && legacyTarget.helper?.state == .done, "an older held answer lands as it was")
        // A source moved into a Private notebook while the AI worked: the gate, asked again right before the result
        // lands, refuses it (the run then fails with this reason, and nothing it produced is published).
        var landingFacts = NoteHelp.GateFacts()
        landingFacts.landing = true
        landingFacts.notebook = "Inbox"
        landingFacts.startNotebook = "Inbox"
        landingFacts.sources = [(id: "S1", notebook: "Research")]
        landingFacts.privateBooks = []
        expect(NoteHelp.admit(landingFacts) == .go, "its sources still readable: the result lands (its AI or its place don't matter any more)")
        landingFacts.privateBooks = ["Research"]
        if case .fail(let why) = NoteHelp.admit(landingFacts) { expect(why.contains("private now"), "a source made Private mid-run: the result is refused at landing, plainly", why) }
        else { expect(false, "a source made Private mid-run fails the run at landing") }
        landingFacts.privateBooks = []
        landingFacts.sources = [(id: "S1", notebook: nil)]
        if case .fail = NoteHelp.admit(landingFacts) { expect(true, "a source gone") } else { expect(false, "a source gone mid-run fails the run at landing") }
        landingFacts.sources = []
        landingFacts.notebook = "Elsewhere"
        if case .fail = NoteHelp.admit(landingFacts) { expect(true, "moved") } else { expect(false, "the destination moved to another notebook mid-run: refused at landing") }
        // A reviewer never changes the primary ink: its result holds only its own opinion, applied onto the paper's
        // ink as it is when it lands. A newer answer synced in from another Mac meanwhile stays, and the opinion says
        // it reviewed an earlier one.
        let newerAnswer = NoteHelp.Ink(who: "✦ Petal", text: "It's the 21st, the page changed.")
        var synced = NoteFile(id: "RV1", created: now)
        synced.ink = [newerAnswer]
        opinionResult.apply(to: &synced)
        expect(synced.ink.count == 2 && synced.ink[0] == newerAnswer && synced.ink[1].opinion && synced.ink[1].who == "GPT 6.1 Sol",
               "a reviewer's result never touches the primary ink: the newer answer stays", "\(synced.ink)")
        expect(NoteHelp.reviewedEarlier(synced.ink[1], among: synced.ink), "and its opinion says it reviewed an earlier answer")
        var same = NoteFile(id: "RV2", created: now)
        same.ink = [answerInk]
        opinionResult.apply(to: &same)
        expect(same.ink[0] == answerInk && !NoteHelp.reviewedEarlier(same.ink[1], among: same.ink), "the answer it reviewed still there: said plainly, nothing added")
        let reviewedBack = NoteFile.parse(same.serialized(), fallbackID: "RV2", fallbackDate: now).ink
        expect(reviewedBack == same.ink && reviewedBack[1].reviewed == NoteHelp.inkHash(answerInk), "which answer it reviewed is kept with the opinion")
        var emptyInk = NoteFile(id: "RV3", created: now)
        NoteHelp.Result(opinion: opinionInk, reviewed: "", helper: .keep).apply(to: &emptyInk)
        expect(emptyInk.ink.count == 1 && emptyInk.ink[0].opinion, "an opinion alone never becomes the primary")
        // A finished answer lands, paused or not: a paused run completes as succeeded; a stopped one never does.
        let pausedDone = RunToken()
        pausedDone.pause()
        expect(pausedDone.complete(.succeeded) && pausedDone.completion == .succeeded && pausedDone.state == .finished, "Pause during the last hop: the finished answer still lands")
        var pausedQueue = FollowUpQueue<String>()
        let pausedAsked = RunToken()
        pausedQueue.add("and then this", note: "N1", token: pausedAsked, line: "follow-up line")
        pausedQueue.addReview(sol, asked: "@Petal have GPT 6.1 Sol look for holes", note: "N1", token: pausedAsked, line: "review line")
        let pausedSettled = pausedQueue.settle(note: "N1", token: pausedAsked, succeeded: false)
        expect(pausedSettled.review == nil && Set(pausedSettled.dropped) == ["follow-up line", "review line"],
               "paused at its end: nothing asked of it is handed on, every line is given back (Pause stops what would happen next)")

        // Where the phases meet: a task's file is found again by the one file resolver (ViewerFiles), on throwaway
        // files: the very file it was put away as wherever it went, never another file that took its path.
        let taskFolder = FileManager.default.temporaryDirectory.appending(path: "petal-task-check-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: taskFolder) }
        let report = taskFolder.appending(path: "Report.txt")
        try? Data("the report".utf8).write(to: report)
        let reportID = ViewerFileID.of(report.path)?.record(mac: "this-mac") ?? ""
        let reportMark = (try? report.bookmarkData())?.base64EncodedString() ?? ""
        let written = NoteHelp.TaskItem(kind: .file, title: "Report.txt", target: report.path, bookmark: reportMark, fileID: reportID)
        let followMark = { (mark: Data) -> URL? in var stale = false; return try? URL(resolvingBookmarkData: mark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
        var taskFile = NoteFile(id: "TK1", created: now)
        taskFile.task = [written, NoteHelp.TaskItem(kind: .tab, title: "Docs", target: "https://example.com/docs")]
        let taskBack = NoteFile.parse(taskFile.serialized(), fallbackID: "TK1", fallbackDate: now)
        expect(!reportID.isEmpty && taskBack.task.first == written, "a task's file keeps its fileID and bookmark in the note")
        // As the Petal Notes window reads the same front matter (NoteContract, Phase 3's reader): the same taskParts, the
        // file's identity with it, and its chips.
        let taskParts = NoteContract.taskItems(taskBack)
        expect(taskParts.count == 2 && taskParts[0].kind == "file" && taskParts[0].target == report.path && taskParts[0].fileID == reportID && taskParts[0].bookmark == reportMark
               && taskParts[1].kind == "tab" && taskParts[1].target == "https://example.com/docs", "the helpers' task reads right in the Petal Notes window", "\(taskParts)")
        expect(taskParts.map(NoteTasks.chip) == ["Report.txt", "example.com"] && NoteContract.tasks(taskBack) == 2, "and its chips and count", "\(taskParts.map(NoteTasks.chip))")
        guard let putAway = taskParts.first else { return expect(false, "a task's file part") }
        let whereNow = { NoteTasks.located(putAway, mac: "this-mac", follow: followMark)?.resolvingSymlinksInPath().path }
        expect(whereNow() == report.path, "a task's file where it was: found", whereNow() ?? "nil")
        let renamed = taskFolder.appending(path: "Report final.txt")
        try? FileManager.default.moveItem(at: report, to: renamed)
        expect(whereNow() == renamed.path, "renamed: found by its identity, wherever it went", whereNow() ?? "nil")
        try? Data("another file at the old path".utf8).write(to: report)
        expect(whereNow() == renamed.path, "another file took its path: Open all still opens the file put away, never that one")
        try? FileManager.default.removeItem(at: renamed)
        let older = NoteContract.TaskItem(kind: "file", title: "Report.txt", target: report.path)
        expect(NoteTasks.located(older, mac: "this-mac", follow: followMark)?.resolvingSymlinksInPath().path == report.path, "a task put away before files were recorded goes by its path")
        expect(NoteTasks.located(NoteContract.TaskItem(kind: "tab", title: "", target: report.path), mac: "this-mac", follow: followMark) == nil, "only a file's part is looked up on the disk")

        // What the Petal Notes window draws from the front matter the helpers write (NoteContract): a watcher's
        // corner number, the older ones struck and an unconfirmed reading; Back; Helpers at work, Watching, Coming back.
        var drawn = NoteFile(id: "DR1", created: now)
        var drawnWatch = NoteHelp.Watch(every: "1d", line: "under $300", mac: "m", at: "09:00")
        drawnWatch.last = "$312"
        drawnWatch.amount = 312
        drawnWatch.history = ["$320", "$335"]
        drawnWatch.unconfirmed = "$289"
        drawnWatch.url = "https://shop.example/item"
        drawn.watch = drawnWatch
        drawn.back = now.addingTimeInterval(3600)
        drawn.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: "Reading the page", asked: "@Petal check this", mac: "m", at: now)
        let asDrawn = NoteFile.parse(drawn.serialized(), fallbackID: "DR1", fallbackDate: now)
        let seen = NoteContract.watch(asDrawn)
        expect(seen?.last == "$312" && seen?.history == ["$320", "$335"] && seen?.every == "1d" && seen?.line == "under $300" && seen?.paused == false,
               "a watcher's corner number, its older ones and what it waits for read right in the window", "\(String(describing: seen))")
        expect(seen?.unconfirmed == "$289" && NoteHelp.corner(asDrawn.watch)?.faint == "$289 · couldn't confirm", "an unconfirmed reading is drawn faintly there too, never as the value")
        expect(NoteContract.back(asDrawn) == asDrawn.back && asDrawn.back != nil, "Back reads the same date")
        let atWork = NoteContract.helper(asDrawn)
        expect(atWork?.state == .working && atWork?.who == "✦ Petal" && atWork?.step == "Reading the page", "a helper at work: its state, who and step", "\(String(describing: atWork))")
        drawn.helper = NoteHelp.Helper(state: .waiting, who: "✦ Petal", step: "Waiting for you: Allow or Don't", at: now)
        expect(NoteContract.helper(NoteFile.parse(drawn.serialized(), fallbackID: "DR1", fallbackDate: now))?.state == .waiting, "waiting for the person: listed as needing them")
        drawn.helper = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", at: now)
        expect(NoteContract.helper(NoteFile.parse(drawn.serialized(), fallbackID: "DR1", fallbackDate: now))?.state == .done, "done: no longer at work")
        drawn.helper = NoteHelp.Helper(state: .failed, who: "✦ Petal", step: "No formula came back.", at: now)
        expect(NoteContract.helper(NoteFile.parse(drawn.serialized(), fallbackID: "DR1", fallbackDate: now)) == nil, "failed: not among the helpers at work (its reason is its ink)")
        var firstReading = NoteHelp.Watch(every: "1d", line: "under $300", mac: "m", at: "09:00")
        firstReading.unconfirmed = "$289"
        var firstFile = NoteFile(id: "DR2", created: now)
        firstFile.watch = firstReading
        let firstSeen = NoteContract.watch(NoteFile.parse(firstFile.serialized(), fallbackID: "DR2", fallbackDate: now))
        expect(firstSeen?.last == "" && firstSeen?.unconfirmed == "$289", "a first reading that couldn't be confirmed: no value yet, its number faint")

        // Readiness: nothing of a helper starts while notes aren't ready (their folder being entered or switched);
        // a finished result still lands (it's held in the journal while its write is refused, and tried again).
        var notReady = NoteHelp.GateFacts()
        notReady.notebook = "Work"; notReady.startNotebook = "Work"; notReady.provider = "claude"; notReady.available = ["claude"]
        notReady.notesReady = false
        if case .wait(let why) = NoteHelp.admit(notReady) { expect(why.contains("getting ready"), "notes not ready: a helper waits, nothing is sent", why) }
        else { expect(false, "notes not ready: a helper waits", "\(NoteHelp.admit(notReady))") }
        notReady.landing = true
        expect(NoteHelp.admit(notReady) == .go, "a finished result isn't refused for it (its write is; it stays in the journal)")
        // A result is held with its notebook as pending work finds it (NotebookBinding), through the journal's file.
        let workBook = NotebookBinding(coverID: "cover-1", path: "Work", instance: "v1:42", root: "/notes/a")
        let heldBound = HelperJournal.adding(NoteHelp.Result(answer: NoteHelp.Ink(who: "✦ Petal", text: "Done."), helper: .keep), note: "BD1", notebook: "Work", book: workBook,
                                         sources: [], at: now, to: [])
        let boundFile = scratch.appending(path: "bound-journal.json")
        expect(HelperJournal.save(heldBound, to: boundFile) && HelperJournal.load(boundFile).first?.book == workBook, "a held result keeps its notebook's binding", "\(HelperJournal.load(boundFile))")
        let places = [NotebookPlace(name: "Work renamed", path: "Work renamed", instance: "v1:42", coverID: "cover-1")]
        expect(NoteShelf.notebookFor(workBook, places: places, complete: true, root: "/notes/a") == .found("Work renamed"), "its notebook renamed meanwhile: still that notebook (not a note moved)")
        expect(NoteShelf.notebookFor(workBook, places: places, complete: true, root: "/notes/b") == .otherRoot, "another notes' folder: never applied there (it waits for its own)")
        let olderEntry = try? JSONDecoder().decode([HelperJournal.Entry].self, from: Data(#"[{"noteID":"X","answer":"---\nid: X\n---\n","at":0}]"#.utf8))
        expect(olderEntry?.first?.book == nil && olderEntry?.count == 1, "an entry kept before bindings still reads")

        // D. An ordinary chat's events are delivered with the vault index unsettled, with no wait: they never pass the
        // ingestion queue or `shield` (which, here, would never come back).
        let never = DispatchSemaphore(value: 0)
        let ingest = DispatchQueue(label: "check.ingest")
        final class Delivered: @unchecked Sendable { var chat: [String] = []; var helper: [String] = []; var shielded = 0 }
        let delivered = Delivered()
        AgentIngest.deliver(["one", "two"], helper: false, queue: ingest, parse: { $0 }, shield: { (events: [String]) -> [(String, Shielded?)]? in
            delivered.shielded += 1
            never.wait()
            return nil
        }, apply: { shown in delivered.chat += (shown ?? []).map(\.0) })
        AgentIngest.after(helper: false, queue: ingest) { delivered.chat.append("ended") }
        // The vault's read blocked for good on the ingestion queue: a chat never notices.
        ingest.async { never.wait() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(delivered.chat == ["one", "two", "ended"] && delivered.shielded == 0, "a chat's events and its end arrive in order with the vault blocked, never shielded on the way", "\(delivered.chat)")
        never.signal()
        // A helper's pass its queue, shielded whole, in order, before anything reads them.
        let helperQueue = DispatchQueue(label: "check.helper")
        AgentIngest.deliver(["a secret step"], helper: true, queue: helperQueue, parse: { $0 }, shield: { $0.map { ("shielded " + $0, nil) } },
                            apply: { shown in delivered.helper += (shown ?? []).map(\.0) })
        AgentIngest.after(helper: true, queue: helperQueue) { delivered.helper.append("ended") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(delivered.helper == ["shielded a secret step", "ended"], "a helper's events are shielded on its queue first, its end after them", "\(delivered.helper)")
        // What a chat is doing, shown outside its panel: redacted now with a settled index, else a plain line; no wait.
        expect(NoteShield.now("Running  deploy --token \(secret)", index: nil).text == "Working…", "the index not made yet: a plain line, never the raw step")
        expect(NoteShield.now("Running  deploy --token \(secret)", index: .unavailable).text == "Working…", "the vault unreadable: a plain line")
        let shownNow = NoteShield.now("Running  deploy --token \(secret)", index: index).text
        expect(shownNow.hasPrefix("Running  deploy") && !shownNow.contains(secret), "the index settled: redacted at once, synchronously", shownNow)

        print("note helpers: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
