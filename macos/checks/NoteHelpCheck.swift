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
        expect(NoteFile.parse("---\nid: P\ncover: true\nprivate: true\n---\n", fallbackID: "x", fallbackDate: now).isPrivate, "a private cover")

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
        let config = "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:Edgetr/petal.git\n\tfetch = +refs/heads/*\n[branch \"main\"]\n\tremote = origin"
        expect(NoteHelp.remotes(config: config) == ["git@github.com:Edgetr/petal.git"], "a git config's remotes")
        expect(NoteHelp.slug(remote: "git@github.com:Edgetr/petal.git") == "edgetr/petal" && NoteHelp.slug(remote: "https://github.com/edgetr/petal") == "edgetr/petal", "remotes' slugs")
        expect(NoteHelp.slug(remote: "git@gitlab.com:a/b.git") == nil, "another host")
        let candidates = [(path: "/u/petal", remotes: ["git@github.com:edgetr/petal.git"]), (path: "/u/petal-old", remotes: ["https://github.com/edgetr/petal"]), (path: "/u/site", remotes: ["git@github.com:edgetr/edgetr.git"])]
        expect(NoteHelp.checkouts(for: "edgetr/petal", among: candidates) == ["/u/petal", "/u/petal-old"], "two checkouts: asked")
        expect(NoteHelp.checkout(holding: "/u/petal/macos/a.swift", among: ["/u/petal", "/u/petal/macos/vendor", "/u/pet"]) == "/u/petal", "the checkout a file is in")
        expect(NoteHelp.branch("Fix the failing check and open a PR", number: 16) == "petal/16-fix-the-failing-check-and-open", "a branch name", NoteHelp.branch("Fix the failing check and open a PR", number: 16))
        let answer = "Opened https://github.com/example/garden/pull/43 into #42.\nProof: run.sh ✓ · diff +4 −2 · PR #43"
        expect(NoteHelp.pullRequest(in: answer) == "https://github.com/example/garden/pull/43" && NoteHelp.proof(in: answer) == ["run.sh ✓", "diff +4 −2", "PR #43"], "the result and its proof")
        expect(NoteHelp.inkText(answer) == "Opened https://github.com/example/garden/pull/43 into #42.", "ink without the proof line")
        expect(NoteHelp.objections(in: "1. The list in Settings still doesn't sort.\n2. No check covers it.") == 2 && NoteHelp.objections(in: "No objections.") == 0, "objections counted")
        expect(NoteHelp.taskChips([.init(kind: .tab, title: "", target: ""), .init(kind: .tab, title: "", target: ""), .init(kind: .file, title: "", target: "/a/Quote-A.pdf")]) == ["2 tabs", "Quote-A.pdf"], "a task's chips")

        print("note helpers: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
