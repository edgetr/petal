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
        expect(NoteFile.parse("---\nid: P\ncover: true\nprivate: true\n---\n", fallbackID: "x", fallbackDate: now).coverPrivate, "a private cover, by its key")

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
        expect(NoteHelp.remotes(config: config).map { "\($0.name) \($0.url)" } == ["origin git@github.com:Edgetr/petal.git"], "a git config's remotes, by name")
        expect(NoteHelp.slug(remote: "git@github.com:Edgetr/petal.git") == "edgetr/petal" && NoteHelp.slug(remote: "https://github.com/edgetr/petal") == "edgetr/petal", "remotes' slugs")
        expect(NoteHelp.slug(remote: "git@gitlab.com:a/b.git") == nil, "another host")
        let candidates: [(path: String, remotes: [(name: String, url: String)])] = [(path: "/u/petal", remotes: [(name: "origin", url: "git@github.com:edgetr/petal.git")]),
                                                                                    (path: "/u/petal-old", remotes: [(name: "origin", url: "https://github.com/edgetr/petal")]),
                                                                                    (path: "/u/site", remotes: [(name: "origin", url: "git@github.com:edgetr/edgetr.git")])]
        expect(NoteHelp.checkouts(for: "edgetr/petal", among: candidates) == ["/u/petal", "/u/petal-old"], "two checkouts: asked")
        expect(NoteHelp.checkout(holding: "/u/petal/macos/a.swift", among: ["/u/petal", "/u/petal/macos/vendor", "/u/pet"]) == "/u/petal", "the checkout a file is in")
        let answer = "Opened https://github.com/example/garden/pull/43 into #42.\nProof: run.sh ✓ · diff +4 −2 · PR #43"
        expect(NoteHelp.pullRequest(in: answer) == "https://github.com/example/garden/pull/43" && NoteHelp.proof(in: answer) == ["run.sh ✓", "diff +4 −2", "PR #43"], "the result and its proof")
        expect(NoteHelp.inkText(answer) == "Opened https://github.com/example/garden/pull/43 into #42.", "ink without the proof line")
        expect(NoteHelp.objections(in: "1. The list in Settings still doesn't sort.\n2. No check covers it.") == 2 && NoteHelp.objections(in: "No objections.") == 0, "objections counted")
        expect(NoteHelp.taskChips([.init(kind: .tab, title: "", target: ""), .init(kind: .tab, title: "", target: ""), .init(kind: .file, title: "", target: "/a/Quote-A.pdf")]) == ["2 tabs", "Quote-A.pdf"], "a task's chips")


        // MARK: Rule A: one cancellable operation per run

        var gate = NoteHelp.Gate(id: 7)
        expect(gate.continues(7) && !gate.continues(6), "a continuation goes on only for its own run")
        expect(gate.pause() && !gate.continues(7) && gate.paused, "paused: no continuation goes on")
        expect(gate.ending(answered: true, asking: false) == .paused, "a turn ending while paused is a pause, not an answer")
        var pausedEnd = gate
        expect(!pausedEnd.end(.paused) && pausedEnd.paused, "a pause advances nothing and stays paused (Go on)")
        expect(gate.goOn() && gate.continues(7), "Go on: running again")
        gate.hold("always:code:/u/garden")
        var revoked = gate
        expect(revoked.revoke("always:code:/u/garden") && !revoked.continues(7), "taking back the grant it works under stops it")
        var other = gate
        expect(!other.revoke("reply") && other.continues(7), "another grant leaves it running")
        var stopped = gate
        stopped.stop()
        expect(stopped.ending(answered: true, asking: false) == .stopped && !stopped.goOn(), "stopped: its answer counts for nothing, and stays stopped")
        expect(!stopped.end(.stopped), "a stopped run advances nothing")
        expect(gate.ending(answered: true, asking: true) == .waitingOnPerson, "asking the person: not done yet")
        expect(gate.ending(answered: false, asking: false) == .failed, "no answer: failed, nothing advances")
        var done = gate
        expect(done.ending(answered: true, asking: false) == .succeeded && done.end(.succeeded), "only a running run with an answer advances")
        expect(!done.end(.succeeded) && !done.continues(7), "once")
        // A watcher's look writes back only its own fields, and only under its own generation.
        var watched: NoteHelp.Watch? = NoteHelp.Watch(every: "1d", line: "under $100", mac: "m", at: "09:00")
        watched?.gen = 3
        expect(NoteHelp.applyLook(&watched, gen: 3, shown: "$99", hint: "from", crossed: true, at: now) == true && watched?.last == "$99" && watched?.hit == true,
               "a look under its own generation: written, newly crossed")
        var pausedWatch = watched
        pausedWatch?.paused = true
        pausedWatch?.gen = 4
        let before = pausedWatch
        expect(NoteHelp.applyLook(&pausedWatch, gen: 3, shown: "$80", hint: nil, crossed: true, at: now) == nil && pausedWatch == before,
               "paused meanwhile: the look writes nothing (Pause stays)")
        var stoppedWatch: NoteHelp.Watch? = nil
        expect(NoteHelp.applyLook(&stoppedWatch, gen: 3, shown: "$80", hint: nil, crossed: true, at: now) == nil && stoppedWatch == nil, "stopped meanwhile: nothing comes back")
        expect(NoteHelp.applyLook(&watched, gen: 3, shown: "$98", hint: nil, crossed: true, at: now) == false, "still under the line: not said again")
        // Its place: the one in front, else wait for it (never what happens to be in front).
        var tabPlace = NoteStick(kind: .tab)
        tabPlace.url = "https://shop.example/x"
        var deskPlace = NoteStick(kind: .desktop)
        deskPlace.desktop = 2
        expect(NoteHelp.anchor([deskPlace, tabPlace], here: 1) == .placed(1), "placed on its window: that place")
        expect(NoteHelp.anchor([deskPlace, tabPlace], here: nil) == .away("shop.example/x"), "brought back on the Desktop: it waits for its page")
        expect(NoteHelp.anchor([deskPlace, tabPlace], here: 0) == .away("shop.example/x"), "shown on a Desktop: still waits for its page")
        expect(NoteHelp.anchor([deskPlace], here: nil) == .free && NoteHelp.anchor([], here: nil) == .free, "only on a Desktop, or nowhere: free")

        // MARK: Rule B: everything told to an AI is shielded first

        let secret = "4111 1111 1111 1111"
        let redact = { (text: String) in text.replacingOccurrences(of: secret, with: "(hidden)") }
        var raw = NoteHelp.Context()
        raw.ask = "pay with \(secret) please"
        raw.body = "# Card \(secret) and more words after it, enough that the title would be cut right through the middle of a secret if cut first\nBody \(secret)"
        raw.notebook = "Book \(secret)"
        raw.cover = "Remembers \(secret)"
        raw.place = "The page \(secret)"
        raw.quote = String(repeating: "x", count: 390) + secret + " tail"
        raw.extra = "Chained answer \(secret)"
        raw.answer = "It said \(secret)"
        raw.labels = ["Label \(secret)"]
        let shown = NoteHelp.shield(raw, redact: redact)
        let told = [NoteHelp.brief(shown), NoteHelp.codeBrief(shown), NoteHelp.codeRequest(shown, checkout: "~/g", tree: "/t", branch: "b", from: "", finish: NoteHelp.finishLine(shown.context.ask)),
                    NoteHelp.reviewRequest(shown, tree: nil), NoteHelp.reviewBrief(shown), NoteHelp.formulaRequest(shown), NoteHelp.awayRequest(shown),
                    NoteHelp.watchConfirm(shown, line: "under $1", found: "$1", hint: ""), NoteHelp.watchFind(shown, line: "under $1", last: "")]
        let digits = String(secret.prefix(9))
        expect(told.allSatisfy { !$0.contains(digits) }, "no prompt carries the secret, whole or cut", told.first { $0.contains(digits) } ?? "")
        expect(NoteHelp.brief(shown).contains("(hidden)") && NoteHelp.brief(shown).contains("Book (hidden)"), "redacted, then said")
        expect(shown.title.hasPrefix("Card (hidden)"), "the title derived after redaction", shown.title)
        var nowhere = NoteHelp.Context()
        nowhere.body = "words"
        expect(NoteHelp.brief(NoteHelp.shield(nowhere, redact: redact)).contains("isn't on a window now"), "a note on no window is told not to look in front")

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
        expect(NoteHelp.worktreeName(checkout: "/Users/someone/garden", noteID: id) == "garden-3f2a9c1d", "one worktree per note")
        expect(NoteHelp.noteKey("file:Inbox/a.md").count == 8 && NoteHelp.noteKey("file:Inbox/a.md") != NoteHelp.noteKey("file:Inbox/b.md"), "an id-less note's key is a hash")
        var withTree = NoteFile(id: "W", created: now)
        withTree.worktree = NoteHelp.Worktree(path: "/t/garden-w", branch: "petal/x-w", checkout: "/u/garden", remote: "upstream")
        expect(NoteFile.parse(withTree.serialized(), fallbackID: "x", fallbackDate: now).worktree == withTree.worktree, "a note's worktree reads back")
        expect(ask("@Petal it's done") == .done, "it's done")

        print("note helpers: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
