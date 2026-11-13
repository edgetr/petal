#!/usr/bin/env bash
# Checks the window maths (tiling), a dock from when the Mac had modes moving into dock.json once (ModesMigration, on
# throwaway folders in the temporary folder), when the dock looks at the windows, and which controls Petal AI is
# told about (UIMap), where notes' tabs and AI sticky notes show and sit (NoteLayout), Petal Notes' files, places, edge tabs and
# room beside a window (NoteFile), how a note works in the background and what its
# preview says (Background), the vault's pure side (sites, 2FA codes, exports, when it fills by itself), and agents
# using the vault (AgentAccess: petal run's variables and redaction, who's asking, projects and grants; worktrees on
# throwaway folders in the temporary folder; writing through a full pipe; an unreadable answer and which signals it
# passes on), the notes for the AI keeping both sides of a change made elsewhere (Instructions), a routine's tidy stopping once its asker hangs up (RoutineStop), a request whose client hung up before its
# turn never being done (IPC, on a throwaway socket), an act's or vault call's Stop seen at once on any thread when its
# caller hangs up (Acting.Cancel), and that every card Petal AI's tools put up names its owner,
# and that the settings list and the AI's tools are well formed and the sources agree with them (Settings), without
# running Petal, moving any window or touching the Keychain:
#   macos/checks/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -O -o "$out/check" Sources/Petal/WindowLayout.swift checks/WindowLayoutCheck.swift
"$out/check"
# The Mac's modes are gone: the default mode's apps become dock.json's, modes.json goes, no other file is written, a
# second launch changes nothing, and an unreadable modes.json gives an empty dock and is left alone.
swiftc -parse-as-library -O -o "$out/modes" Sources/Petal/ModesMigration.swift checks/ModesMigrationCheck.swift
"$out/modes"
# The settings, in one list: no key twice, every one with help and a default of its type, and every read of a setting
# in the sources naming one that's listed, as the type it is. The AI's tools (Resources/mcp/tools.json): valid, no name
# twice, each with a description and an input schema, and the same tools MCP.swift does.
swiftc -parse-as-library -O -o "$out/settings" Sources/Petal/Settings.swift checks/SettingsCheck.swift
"$out/settings" Resources/mcp/tools.json Sources/Petal
swiftc -parse-as-library -O -o "$out/look" Sources/Petal/LookSchedule.swift checks/LookScheduleCheck.swift
"$out/look"
# What apps signal to the dock: a badge going up bounces its app once (never every badge when Petal or macOS's Dock
# starts, and a dot becoming a count is going up), and a player playing shows before one paused (SignalRules).
swiftc -parse-as-library -O -o "$out/signals" Sources/Petal/SignalRules.swift checks/SignalRulesCheck.swift
"$out/signals"
# Clicking an app in front again brings its next window forward, through every one of them and back, whatever order
# the app lists them in as they come forward; which running apps the dock lists and their dots; what letting go of a
# dragged app does (a wobble is a click, out of the dock removes it); what a drop adds or opens; and windows kept
# clear of the dock, look after look, over 1500 generated runs (screens left of and above the main one, docks on
# every side, apps that keep a minimum size, looks a moment old, the person dragging and resizing into the strip):
# Petal stops moving windows within a few looks, a window dragged in at its size goes back out at that size and is
# never shortened later, nothing creeps, and turning it off gives every window back (DockRules).
swiftc -parse-as-library -O -o "$out/dockrules" Sources/Petal/DockRules.swift checks/DockRulesCheck.swift
"$out/dockrules"
# Magnification: the icon under the pointer grows by the amount set and stays under it, its neighbours ease aside
# without overlapping, the glass stretches with them, nothing grows past the room the panel keeps, and the zone the
# pointer counts as at the dock (MagnifyRules). `Petal --bench-dock` drives the real dock the same way.
swiftc -parse-as-library -O -o "$out/magnify" Sources/Petal/MagnifyRules.swift checks/MagnifyRulesCheck.swift
"$out/magnify"
# Petal's own files: an entry in dock.json's apps that isn't text never empties the dock, a file someone is
# editing that doesn't read as JSON yet keeps what was read before, and a change in settings.json that would let Petal
# AI do more (Full access, using apps, more allowed without asking, an app off the private list) isn't taken while
# Petal runs, while one that lets it do less is (ConfigRules).
swiftc -parse-as-library -O -o "$out/configrules" Sources/Petal/ConfigRules.swift checks/ConfigRulesCheck.swift
"$out/configrules"
# A website shortcut's cached icon: an ask while it's being read waits for that read, so a cached icon is never
# fetched from the site again (SiteLoads).
swiftc -parse-as-library -O -o "$out/siteloads" Sources/Petal/SiteLoads.swift checks/SiteLoadsCheck.swift
"$out/siteloads"
# A stack's thumbnails: made once at a time, and made again when asked for after the cache let them go (ThumbnailCache).
swiftc -parse-as-library -O -o "$out/thumbnails" Sources/Petal/ThumbnailCache.swift checks/ThumbnailCacheCheck.swift
"$out/thumbnails"
swiftc -parse-as-library -O -o "$out/uimap" Sources/Petal/UIMap.swift checks/UIMapCheck.swift
"$out/uimap"
# A window's words for petal_look's text (WindowText): reading order, a page without its browser's toolbar, the cap
# and the next part, find, a secret hidden whole or in pieces, a password field left out.
swiftc -parse-as-library -O -o "$out/windowtext" Sources/Petal/UIMap.swift checks/WindowTextCheck.swift
"$out/windowtext"
# What petal_act says of a menu is its app's own text (a Window menu lists every window by its title): the items a
# menu has, the path walked and the item chosen are told only in UIMap's words, every title through the vault's
# redaction (Acting.menuWords); the title Petal goes by (menuTitle) is never told.
if grep -nE 'chose = prepared\.menuTitle|\\\((prepared|known)\.menuTitle|It has: |The menus are: ' Sources/Petal/ComputerUse.swift Sources/Petal/BackgroundActing.swift; then
    echo "petal_act: a menu's titles are told only through Acting.menuWords"; exit 1
fi
grep -q 'menuWords { UIMap.noMenu(path\[0\], menus: names, shown: \$0) }' Sources/Petal/ComputerUse.swift \
    && grep -q 'menuWords { UIMap.noMenuItem(name, in: walked, items: names, shown: \$0) }' Sources/Petal/ComputerUse.swift \
    && [ "$(grep -c 'menuWords { UIMap.menuShown(' Sources/Petal/ComputerUse.swift)" = 2 ] \
    && grep -q 'VaultIndex.settled { index in words { index.redacted(\$0) } } ?? words { _ in UIMap.hidden }' Sources/Petal/ComputerUse.swift \
    || { echo "petal_act: a menu's titles go through the vault's redaction before they're told"; exit 1; }
# A menu item or key that hands what's selected to another app without the clipboard (UIMap.sends: a Service, Share,
# Look Up) gets a copy's check right before it, in front and in the background alike; the app's own menu, where
# Services is in every language, is known by its place (UIMap.ownMenu), for a menu path and a key's item alike; in
# the background such an item needs the window in front. And the text Services (Ask Petal AI, Add to Petal AI) quote
# the text only as Petal AI may be told it, each vault secret hidden.
grep -q 'case .send?: return copyRefusal(map, element, sending: true)' Sources/Petal/ComputerUse.swift \
    && grep -q 'return UIMap.sends(menu: title ?? own, appMenu: appMenu, character: character, modifiers: modifiers) ? .send : nil' Sources/Petal/ComputerUse.swift \
    && grep -q 'key.map { UIMap.sends(key: \$0, claimed: false) } ?? UIMap.sends(menu: title, appMenu: appMenu)' Sources/Petal/ComputerUse.swift \
    && [ "$(grep -c 'UIMap.ownMenu(at:' Sources/Petal/ComputerUse.swift)" = 2 ] \
    && [ "$(grep -c 'prepared.menuApp = found.appMenu' Sources/Petal/ComputerUse.swift)" = 2 ] \
    && [ "$(grep -c 'if sends, let why = sendRefusal(map, ' Sources/Petal/BackgroundActing.swift)" = 2 ] \
    && grep -q '(sends && prepared.menuItem != nil)' Sources/Petal/BackgroundActing.swift \
    && grep -q 'let shown = Assist.shownText(text, limit: .max)' Sources/Petal/TextServices.swift \
    && ! grep -q 'app.claude.quote(text, ' Sources/Petal/TextServices.swift \
    || { echo "petal_act: what hands the selection to another app is checked as a copy; the text Services quote no vault secret"; exit 1; }
# petal_windows finds a window by its id or by words of the title it told, never by its own title's hidden words.
if grep -n '\$0\.title\.localizedCaseInsensitiveContains(wanted)' Sources/Petal/Assist.swift; then
    echo "petal_windows: a window is found only by the title as it was told"; exit 1
fi
echo "menus: titles told redacted; handing the selection on checked as a copy"
swiftc -parse-as-library -O -o "$out/notes" Sources/Petal/NoteLayout.swift checks/NoteLayoutCheck.swift
"$out/notes"
# Petal Notes: the note file's round trip, iCloud's conflict copies, the ranked fallback of a note's places, the tabs
# on a window's edge, fading, and the room beside a window (no file, no window).
swiftc -parse-as-library -O -o "$out/papernotes" Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift checks/NotesCheck.swift
"$out/papernotes"
# The Petal Notes window, canvas, dock and people: the contract's fields, views, search, the grid and cover, Private
# notebooks, one person or none, the canvas's based write, the fan and a note dropped on an app (no file, no window).
swiftc -parse-as-library -O -o "$out/notelibrary" Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift Sources/Petal/NoteTasks.swift Sources/Petal/RunApps.swift Sources/Petal/ViewerFile.swift checks/NoteLibraryCheck.swift
"$out/notelibrary"
# A note's text in the editor and back: the same Markdown, line for line (AppKit, nothing shown).
swiftc -parse-as-library -O -o "$out/noterich" Sources/Petal/Screens.swift Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/NoteMentions.swift Sources/Petal/NoteEditor.swift Sources/Petal/NoteTasks.swift Sources/Petal/RunApps.swift Sources/Petal/ViewerFile.swift Sources/Petal/EditMenu.swift Sources/Petal/Scale.swift checks/NoteRichCheck.swift
"$out/noterich"
# Petal Notes' files on throwaway folders in the temporary folder: saves that keep both, names from the disk, no
# writes through symbolic links, two notebooks' Todo.md, a renamed file's bookmark, the journal's launch recovery
# after a hang, and a cancelled tool write leaving nothing (never the Trash).
# Helpers in notes: what an @ line binds and asks, the helper's front matter (ink, steps, stamps, a watcher, a task, a
# chain) read back exactly, times and models in words, prices on a page, a notebook's memory, plain arithmetic,
# chained notes' loops and the person's checkouts (no window, no AI), and Open all never launching an app or a script
# (NoteTasks: real files, a link and a Finder alias in a throwaway folder in the temporary folder; nothing is opened).
swiftc -parse-as-library -O -o "$out/notehelp" Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/NoteTasks.swift Sources/Petal/RunApps.swift Sources/Petal/ViewerFile.swift checks/NoteHelpCheck.swift
"$out/notehelp"
# The helpers' clock does only what the person set up on this Mac (NoteLocal.standing, NoteHelp.stands, checked
# above): a watcher's look, a chain's start and a morning note each ask it first, in the clock and again where the
# look and the start begin; and each of the three is kept when the person's own line makes it.
perl -0777 -ne '
    my @kept = (/keepGoing\(NoteHelp\.Standing\(/g);
    unless (/if let watch = file\.watch, watch\.mac == mac, stands\(NoteHelp\.Standing\(watch, on: paper\.noteID\)\), NoteHelp\.due\(/
            && /if let chain = file\.chain, stands\(NoteHelp\.Standing\(chain, on: paper\.noteID\)\),\s*chain\.ready\(/
            && /if let morning = file\.morning, morning\.mac == mac, stands\(NoteHelp\.Standing\(morning: morning\.time, on: paper\.noteID\)\),/
            && /guard var chain = paper\.file\.chain, runs\[paper\.noteID\] == nil, stands\(NoteHelp\.Standing\(chain, on: paper\.noteID\)\) else \{ return \}/
            && /let watch = paper\.file\.watch, watch\.mac == mac, stands\(NoteHelp\.Standing\(watch, on: noteID\)\),/
            && @kept == 3 && /process\.arguments = NoteHelp\.mergedArguments\(link\)/) {
        print "NoteHelpers: the clock acts only on a chain, watcher or morning note this Mac keeps\n"; exit 1 }
    print "helpers: the clock does only what was set up on this Mac\n";
' Sources/Petal/NoteHelpers.swift
# A click on a link in a note goes through NoteTasks alone (a web or mail address, a file by Open all's rule, else
# nothing): the editor and the paper open nothing themselves.
if grep -n 'NSWorkspace.shared.open' Sources/Petal/NoteEditor.swift Sources/Petal/NoteViews.swift; then echo "A note's link opened outside NoteTasks"; exit 1; fi
grep -q 'NoteTasks.openLink(link)' Sources/Petal/NoteEditor.swift || { echo "NoteEditor: a clicked link goes through NoteTasks.openLink"; exit 1; }
echo "notes: a link in a note opens only through NoteTasks"
# petal_ui, petal_act and a vault fill never read or use Petal's own windows (UIMap.petalsOwn, checked above).
[ "$(grep -c 'if let own = UIMap.petalsOwn(' Sources/Petal/ComputerUse.swift)" = 2 ] && grep -q 'UIMap.petalsOwn(map.pid) == nil' Sources/Petal/VaultFill.swift \
    || { echo "ComputerUse: petal_ui, petal_act and vault fills refuse Petal's own process"; exit 1; }
echo "computer use: never Petal's own windows"
# The Shielded boundary is the compiler's: what a helper tells an AI can't be made from a raw string. Each of these
# must fail to compile (a raw string interpolated into a prompt, put into what a helper is told, or made Shielded
# outside NoteShield), and the shielded way must compile.
shielded=(Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift)
boundary() {
    printf '@main struct B { static func main() {\n let raw = String(CommandLine.arguments.count)\n %s\n } }\n' "$2" > "$out/boundary.swift"
    if swiftc -parse-as-library -o "$out/boundary" "${shielded[@]}" "$out/boundary.swift" >/dev/null 2>&1; then built=yes; else built=no; fi
    if [ "$built" != "$1" ]; then echo "Shielded boundary: expected compiling '$2' to be $1"; exit 1; fi
}
boundary no 'let p: Shielded = "ask: \(raw)"; print(p)'
boundary no 'let t = NoteHelp.Told(ask: raw); print(NoteHelp.brief(t))'
boundary no 'var t = NoteHelp.Told(); t.extra = raw; print(t)'
boundary no 'print(Shielded(verified: raw))'
boundary no 'print(NoteHelp.watchFind(raw))'
boundary no 'print(NoteHelp.system(NoteHelp.Told(), provider: raw, computerUse: false, brief: ""))'
boundary no 'print(NoteHelp.system(NoteHelp.Told(), provider: "Claude", computerUse: false, brief: "\(raw)"))'
boundary no 'var t = NoteHelp.Told(); t.place = raw; t.instructions = raw; print(NoteHelp.system(t, provider: "Claude", computerUse: false, brief: ""))'
boundary yes 'if let s = NoteShield.shield([raw], index: UIMap.SecretIndex([])) { let p: Shielded = "ask: \(s[0]) \(3)"; print(NoteHelp.brief(NoteHelp.Told(ask: p))) }'
echo "Shielded boundary: a raw string never makes a helper's prompt"
# What Petal AI did (ai-history.json): a line is Petal's own words, and whatever it names goes in only as a name
# (HistoryLine), redacted with the vault's index before it's kept (Assist.did, the one way in). The compiler's again:
# a raw string is not a line, and can't be put into one; the named way compiles and leaves a name out when it must.
history() {
    printf '@main struct H { static func main() {\n let raw = String(CommandLine.arguments.count)\n func did(_ line: HistoryLine) { print(line.text(nil), "|", line.text { _ in "(hidden)" }) }\n %s\n } }\n' "$2" > "$out/history.swift"
    if swiftc -parse-as-library -o "$out/history" Sources/Petal/HistoryLine.swift "$out/history.swift" >/dev/null 2>&1; then built=yes; else built=no; fi
    if [ "$built" != "$1" ]; then echo "History line: expected compiling '$2' to be $1"; exit 1; fi
}
history no 'did(raw)'
history no 'did("Quit \(raw)")'
history no 'let line: HistoryLine = "Closed “\(raw)”"; did(line)'
history no 'did("Quit " + raw)'
history yes 'did("Quit \(named: raw, else: "an app") and \(quoted: raw, else: "a window"), \(3) times")'
[ "$("$out/history")" = "Quit an app and a window, 3 times | Quit (hidden) and “(hidden)”, 3 times" ] || { echo "History line: a name left out, or redacted: $("$out/history")"; exit 1; }
# One `did`, taking only a line; nothing makes a line from a string by its initializer; an entry is made nowhere else.
[ "$(cat Sources/Petal/*.swift | grep -c 'func did(')" = 1 ] && grep -q 'func did(_ line: HistoryLine, undo: Undo? = nil)' Sources/Petal/AssistMore.swift \
    && ! grep -n 'HistoryLine(stringLiteral\|HistoryLine(stringInterpolation\|HistoryLine\.init\|as HistoryLine' Sources/Petal/*.swift \
    && [ "$(grep -l 'Done(at:' Sources/Petal/*.swift | tr '\n' ' ')" = "Sources/Petal/AssistMore.swift " ] \
    || { echo "Assist.did: every line of What Petal AI did goes through the one function, as a HistoryLine"; exit 1; }
echo "history: a raw string never makes a line of What Petal AI did"
# A helper's quick calls go through Brain's Shielded overload only (the one that takes its run's token).
if grep -nE 'brain\.ask\(' Sources/Petal/NoteHelpers.swift | grep -v 'token:'; then echo "NoteHelpers: a Brain call without its Shielded prompt and token"; exit 1; fi
# Every run ends in one of three outcomes, early exits too: each `return` in a chat turn's start (Agent.run) is a
# refusal (a failed outcome through agentFinished) or its run's wait; and in the helpers, a bare `return` from a guard
# about a run only follows a check of that run's token (someone else reported its end).
perl -0777 -ne '
    if (/private func run\(_ prompt: String\) \{(.*?)\n    \}\n/s) {
        my $body = $1; my $n = 0;
        # The start'"'"'s own statements (eight spaces in; the closures for its output are deeper) and its launch error.
        while ($body =~ /^( {8}\S.*\breturn\b.*)$/mg) {
            my $line = $1;
            next if $line =~ /return refuse\(/ || $line =~ /waiting\.append\(prompt\); return/;
            print "Agent.run: an early return without an outcome: $line\n"; $n++;
        }
        if ($body !~ /\} catch \{[^}]*return refuse\(/s) { print "Agent.run: a launch error without an outcome\n"; $n++ }
        exit 1 if $n; print "outcomes: every early return of a turn reports one\n";
    } else { print "Agent.run not found\n"; exit 1 }
' Sources/Petal/Claude.swift
perl -ne '
    # (A function named …OrFail( reports the failure of the run itself before it returns nil.)
    # (`mine(run)`: still that run, not ended. `guard let self, let run`: a closure whose run is gone. `run?.`: the same.)
    if (/\bguard\b.*\brun\b.*else \{ return \}/ && !/live\(|mine\(|admits|token\.|runs\[|OrFail\(|let self, let run\b|run\?\./) { print "NoteHelpers:$.: a run guard that returns without an outcome: $_"; $bad++ }
    END { exit 1 if $bad; print "outcomes: every helper run guard reports one or checks its token\n" }
' Sources/Petal/NoteHelpers.swift
# A helper's writes go only through the note's session as Petal's own change (journaled at once, drained at quit):
# no queue of its own, and never a tool's write that shows only once it lands.
if grep -nE 'queued\[|store\.change\([^)]*live:' Sources/Petal/NoteHelpers.swift; then echo "NoteHelpers: a write outside the note's session"; exit 1; fi
# Nothing of a helper's setup reads the disk on the main thread: every file read in NoteHelpers is in a static
# function (they run off the main thread).
perl -ne '
    $func = $_ if /^\s*(?:private |nonisolated |@MainActor )*(?:static )?func /;
    if (/contentsOf:/ && $func !~ /\bstatic func\b/) { print "NoteHelpers:$.: a file read on the main thread: $_"; $bad++ }
    END { exit 1 if $bad; print "helpers: no file read on the main thread\n" }
' Sources/Petal/NoteHelpers.swift
# A running helper follows its note's places only after `here` is recomputed (in apply, right after it).
perl -0777 -ne '
    my @calls = (/helpers\.placesFollow\(\)/g);
    unless (@calls == 1 && /if fits != here \{ here = fits \}\n[^\n]*\n\s*helpers\.placesFollow\(\)/) { print "NoteDesk: placesFollow must come right after here is recomputed\n"; exit 1 }
    print "helpers: places followed after here is known\n";
' Sources/Petal/NoteDesk.swift
# A helper's command rules belong to its run: a new token clears them (Agent.token adopts it).
perl -0777 -ne '
    unless (/var token: RunToken\? \{[^}]*didSet \{ if token !== oldValue \{ allowedRules\.adopt\(token\) \} \}/s && /private var allowed: \[String\] \{\s*get \{ allowedRules\.value \}/s) { print "Agent: command rules must belong to the run token\n"; exit 1 }
    print "helpers: command rules scoped to the run\n";
' Sources/Petal/Claude.swift
# A note tool tells of a Private notebook's notes only inside it, by the one fence (NotePrivacy, Phase 3's `deliver`:
# checked again right before every answer is handed over); the helpers' own recheck is gone. `asker` is the helper's
# note (its paper's id), `caller` its chat (whose answer shows the notes it used as chips).
perl -0777 -ne '
    unless (/let deliver = .*?NotePrivacy\.deliverable\(notebooks: now, privateBooks: self\.store\.privateBooks, asker: insideNow\)/s
            && /guard let paper = self\.repick\(chosen\), readable\(paper\.notebook\) else/ && !/stillReadable|sendAbout|visibleAfterWait|helpers\.mayRead/
            && /func handle\(_ name: String, _ args: \[String: Any\], asker: String\? = nil, caller: String\? = nil,/ && /used\(\[paper\]\)/) {
        print "NoteTools: one Private fence on every answer, and the notes a chat used\n"; exit 1 }
    print "notes: every tool answer through the one Private fence\n";
' Sources/Petal/NoteTools.swift
grep -q 'app.paper.handle(name, args, asker: note.flatMap { app.claude.note(withID: $0)?.paper }, caller: note, live: live, send, fail)' Sources/Petal/Assist.swift \
    || { echo "Assist: a note tool is asked with the helper's note (asker) and its chat (caller)"; exit 1; }
# A file helper's document is revalidated on every placement change, by the one file resolver (NoteMatch.fits, which
# asks ViewerFiles' answer for the window in front, or the file Petal's viewer shows): never a path compared. A file's
# repository, and a task's file at Open all, are found by ViewerFiles.locate (identity, then bookmark, then path).
grep -q 'return desk?.scene.map { NoteMatch.fits(required, $0) } ?? false' Sources/Petal/NoteHelpers.swift \
    && grep -q 'if required.map({ place.samePlace($0) }) ?? true { return (model, place) }' Sources/Petal/NoteHelpers.swift \
    && grep -q 'let file = ViewerFiles.locate(stick, mac: mac, follow: ViewerLoader.follow)?.path' Sources/Petal/NoteHelpers.swift \
    && grep -q 'if work, let stick, ViewerFiles.namesFile(stick) {' Sources/Petal/NoteHelpers.swift \
    && grep -q 'if item.kind == "file" { return located(item, mac: mac, follow: follow).map(decide) }' Sources/Petal/NoteTasks.swift \
    && ! grep -n 'documentShowing\|sceneFile\|run\.document' Sources/Petal/NoteHelpers.swift Sources/Petal/NoteHelp.swift \
    || { echo "NoteHelpers: a helper's files go by the one file resolver, never a path comparison"; exit 1; }
# The final review's three (Petal --helpers-check drives them, steps 11 to 13; these keep their shape in the source):
# a run takes the private apps' generation when it's made, never a default; Allow's continuation is the run's own
# call through `start`, in the place the run kept while it asked; a note in the viewer's margin has that viewer's
# window as its place. And a headless run never orders a window of Petal's in.
grep -q 'self.privacy = ClaudePanel.privacy.now' Sources/Petal/NoteHelpers.swift \
    && ! grep -q 'var privacy = 0' Sources/Petal/NoteHelpers.swift \
    || { echo "NoteHelpers: a run takes the private apps' generation when it's made"; exit 1; }
grep -q 'guard agent.takeAllow() else { return }' Sources/Petal/NoteHelpers.swift \
    && grep -q 'start(run, turn(run, said: nil, words: { _ in Agent.approvedWords }))' Sources/Petal/NoteHelpers.swift \
    && ! grep -q 'agent\.allow()' Sources/Petal/NoteHelpers.swift \
    && grep -q 'var holdsPlace: Bool { running || (helperSystem != nil && (!pendingAsk.isEmpty || continuing)) }' Sources/Petal/Claude.swift \
    && grep -q 'app.claude.working(besides: self) >= ClaudePanel.atOnce' Sources/Petal/Claude.swift \
    && grep -q 'var working: Int { notes.filter { $0.agent.holdsPlace }.count }' Sources/Petal/StickyNotes.swift \
    || { echo "NoteHelpers: Allow's continuation goes through start, in the place its run kept"; exit 1; }
grep -q 'return viewing.flatMap { app.viewers.place(of: $0) }' Sources/Petal/NoteHelpers.swift \
    && grep -q 'if viewer(showing: run.noteID, on: required) != nil { return true }' Sources/Petal/NoteHelpers.swift \
    && grep -q 'func place(of model: ViewerModel) -> NotePlace?' Sources/Petal/Viewer.swift \
    || { echo "NoteHelpers: a note in the viewer's margin has that viewer's window as its place"; exit 1; }
awk '/static func bringForward\(_ window: NSWindow\)/,/^    }$/' Sources/Petal/PetalWindow.swift | grep -q 'guard !Headless.on else { return }' \
    || { echo "PetalWindow: a headless run never orders a window in"; exit 1; }
echo "helpers: the private apps' generation, Allow's continuation and the viewer as a place keep their shape"
echo "helpers: a helper's documents and a task's file go by the one file resolver"
# The viewer's tools tell an agent only of notes it may read, and write only those into a PDF for it (a Private
# notebook's never leave it); a helper is answered only through its admission gate (Assist.handle wraps every tool).
perl -0777 -ne '
    unless (/func readable\(_ paper: PaperNote, by caller: String\?\) -> Bool \{\s*guard let caller else \{ return true \}.*?return helpers\.mayRead\(paper\.notebook, from: asking\)/s
            && /result\["notes"\] = model\.notes\.filter \{ readable\(\$0\.paper, by: caller\) \}\.count/
            && /guard paper\.version == nil, readable\(paper, by: caller\),/ && /var told = self\.told\(model, caller: caller\)/) {
        print "ViewerTools: an agent is told of, and handed, only the notes it may read\n"; exit 1 }
    print "viewer tools: only the notes their asker may read\n";
' Sources/Petal/ViewerTools.swift
grep -q 'app.viewers.handle(name, args, caller: note ?? "petal", live: live, send, fail)' Sources/Petal/Assist.swift || { echo "Assist: the viewer tools answer through handle (the helpers gate)"; exit 1; }
# Where the helpers meet the Notes window's phase. Readiness: no helper starts, nothing of the clock runs and nothing
# is written while notes aren't ready (NoteDesk.takesChanges / acceptsChanges; the gate waits), and a write that's
# refused is always heard, its result kept in the helpers' journal and tried again. Private notebooks come from
# NotePrivacy over NoteStore.privateBooks, nowhere else. One NoteTasks, one Open all. What's kept per notebook goes by
# its binding (NotebookBinding, NoteShelf.notebookFor): a rename isn't a move, another notes' folder is never used.
perl -0777 -ne '
    unless (/func returned\(_ key: String, line: String, at ticket: NoteLine\) \{(?:(?!\n    \}\n).)*?guard desk\.takesChanges\(\) else \{ return \}(?:(?!\n    \}\n).)*?ticket\.take\(\)|func returned\((?:(?!\n    \}\n).)*?guard desk\.takesChanges\(\) else \{ return \}/s
            && /func write\(_ noteID: String, touch: Bool = false,[^\n]*\n\s*guard let desk, desk\.acceptsChanges, let paper = paper\(noteID\)/
            && /private func tick\(\) \{\s*(?:\/\/[^\n]*\n\s*)*guard let desk, desk\.on, desk\.acceptsChanges else \{ return \}/
            && /func applyHeld\(\) \{\s*(?:\/\/[^\n]*\n\s*)*guard let desk, desk\.acceptsChanges else \{ return \}/
            && /facts\.notesReady = desk\?\.acceptsChanges \?\? false/) {
        print "NoteHelpers: nothing starts, runs or is written while notes are not ready\n"; exit 1 }
    unless (/return NotePrivacy\.readable\(notebook: notebook, privateBooks: store\.privateBooks, asker: paper\?\.notebook\)/
            && !/coverPrivate|NoteHelp\.Privacy|CoverFiles|visibleAfterWait|scalarValue\("private"\)|value\("private"\)/) {
        print "NoteHelpers: Private notebooks come from NotePrivacy only\n"; exit 1 }
    unless (/run\.startBook = store\?\.binding\(paper\.notebook\)/ && /if let book = entry\.book, case \.otherRoot = desk\.store\.resolve\(book\) \{ continue \}/
            && /guard store\.session === session, case \.found\(let notebook\) = store\.resolve\(book\) else/
            && /let stable = "morning-" \+ NoteShelf\.pictureFolder\(id: cover\.noteID\)/ && /func folderSwitching\(\) \{\s*for run in Array\(runs\.values\) \{ end\(run, \.stopped\(nil\)\) \}/) {
        print "NoteHelpers: what is kept per notebook goes by its binding and its notes folder\n"; exit 1 }
    print "helpers: ready before anything starts or is written; Private from NotePrivacy; notebooks by their binding\n";
' Sources/Petal/NoteHelpers.swift
! grep -n 'coverPrivate\|enum Privacy\|struct CoverFiles\|visibleAfterWait' Sources/Petal/NoteHelp.swift || { echo "NoteHelp: the helpers keep no reading of privacy of their own"; exit 1; }
[ "$(cat Sources/Petal/*.swift | grep -c '^enum NoteTasks')" = 1 ] && ! grep -n '^extension NoteTasks' Sources/Petal/*.swift \
    && [ "$(cat Sources/Petal/*.swift | grep -c 'NoteTasks\.openAll(')" = 1 ] && grep -q 'NoteTasks.openAll(items, mac: local.mac, follow: { ViewerLoader.follow($0) })' Sources/Petal/NoteDesk.swift \
    && grep -q 'desk?.openAll(NoteContract.taskItems(paper.file))' Sources/Petal/NoteHelpers.swift && grep -q 'Button { app.paper.openAll(items) } label: {' Sources/Petal/NotesWindow.swift \
    || { echo "NoteTasks: one enum and one Open all, for the note and the Petal Notes window alike"; exit 1; }
echo "tasks: one NoteTasks, one Open all"
perl -0777 -ne '
    my $heard = () = /done\?\(\.failed\)/g;
    unless ($heard == 3 && /let next = store\.change\(key, base: base, edit: \{ \$0\.body = body; also\?\(&\$0\) \}, done: done\)\s*(?:\/\/[^\n]*\n\s*)*if next == nil \{ done\?\(\.failed\) \}/
            && /helpers\.folderSwitching\(\)\s*(?:\/\/[^\n]*\n\s*)*app\.viewers\.folderSwitching\(true\)/) {
        print "NoteDesk: a refused write with a helper change is always heard; a folder switch ends the helpers runs ($heard)\n"; exit 1 }
    print "notes: a refused write is heard; a switch of the notes folder ends its helpers whole\n";
' Sources/Petal/NoteDesk.swift
# Rule C: one admission gate. Every prompt a helper's agent gets, and every quick call, goes through NoteHelpers.start
# (whose `prepare` asks admit right before the words are built), every turn's process starts only after the agent asks
# its gate, every tool answer to a helper goes through admitTool (before the tool, and again right before its answer),
# and a completion counts only for its own token.
perl -ne '
    $func = $1 if /^\s*(?:private |nonisolated |@MainActor )*(?:static )?func (\w+)/;
    if (/\.send\(|brain\.ask\(/ && $func ne "start") { print "NoteHelpers:$.: a prompt sent outside start (the one launch): $_"; $bad++ }
    $admits++ if $func eq "prepare" && /return self\.admit\(run\)/;
    $matches++ if /NoteHelp\.completionMatches\(turn:/;
    END { exit 1 if $bad || !$admits || !$matches; print "rule C: every prompt goes through admit; completions match their token\n" }
' Sources/Petal/NoteHelpers.swift
perl -0777 -ne '
    unless (/guard admitted else .*?\n\s*if let gate \{\s*switch gate\(\)/s) { print "Agent.run: a turn must ask its gate before its process starts\n"; exit 1 }
    print "rule C: every turn asks its gate before its process starts\n";
' Sources/Petal/Claude.swift
perl -0777 -ne '
    unless (/reply answer: \@escaping .*?let reply: \@MainActor \(String\) -> Void = \{ \[weak self\] text in\s*if let refusal = self\?\.app\.paper\.helpers\.admitTool\(note\)/s
            && /if let refusal = app\.paper\.helpers\.admitTool\(note\) \{/) { print "Assist.handle: every tool answer to a helper must go through admitTool\n"; exit 1 }
    print "rule C: every tool answer to a helper goes through admit\n";
' Sources/Petal/Assist.swift
# An automatic approval (an earlier Always, Full access) is registered on the asking helper run's token first.
perl -0777 -ne '
    unless (/let grant = NoteHelp\.autoGrant\(.*?\) \{\s*return done\(app\.paper\.helpers\.authorized\(owner, grant\)\)/s) { print "Assist.ask: an automatic approval must register on the run first\n"; exit 1 }
    print "helpers: automatic approvals register on the run\n";
' Sources/Petal/Assist.swift
# Everything a run produced (ink, an opinion, steps, a formula, a task) is one result (NoteHelp.Result), through the
# held-answer journal (keep): nothing of it is written beside that, and an entry is let go only when its write landed
# on the paper meant (.written, never .keptBoth).
perl -ne '
    if (/\.(ink|calc|task|steps)\s*(=|\+=)[^=]/ && !/^\s*\/\//) { print "NoteHelpers:$.: a run output written outside its one result: $_"; $bad++ }
    $kept++ if /\bkeep\(run, (self\.)?result\(run, /;
    $written++ if /done\?\(outcome == \.written\)/;
    END { exit 1 if $bad || $kept < 4 || $written < 2; print "helpers: every output is one result through the journal; only .written lets it go\n" }
' Sources/Petal/NoteHelpers.swift
# One agent per run: a run's agent is made fresh (sticky(for:)) and goes when the run ends; none is reused.
perl -0777 -ne '
    my $made = () = /StickyNote\(\)/g;
    unless ($made == 1 && /func sticky\(for paper: PaperNote\) -> StickyNote \{\s*let sticky = StickyNote\(\)/ && /let sticky = run\.sticky \?\? sticky\(for: paper\)/
            && /let reviewer = sticky\(for: paper\)/ && /func retire\(_ run: Run\) \{\s*if let sticky = run\.sticky \{.*?\n\s*drop\(sticky\)\n/s) {
        print "NoteHelpers: every run must get a fresh agent of its own, dropped when it ends\n"; exit 1 }
    print "helpers: a fresh agent for every run\n";
' Sources/Petal/NoteHelpers.swift
# A tool's admission changes the run: failing fails it, waiting parks it (resumable), a privacy change rebuilds it.
perl -0777 -ne '
    unless (/func admitTool.*?case \.fail\(let reason\):.*?\bfail\(run, reason.*?case \.park\(let reason\):.*?\bpark\(run, reason\).*?case \.rebuild:\s*rebuild\(run\)/s
            && /facts\.builtPrivacy = run\.privacy/ && /facts\.placePrivate = /) { print "NoteHelpers: tool admission outcomes and privacy must change the run\n"; exit 1 }
    print "helpers: tool admissions fail, park or rebuild the run; privacy is checked at the gate\n";
' Sources/Petal/NoteHelpers.swift
# A form fits the screen: its fields scroll, its buttons (Submit, Allow, Don't, Buy) stay outside the scroll, and
# the paper keeps the controls' measured room.
grep -q 'if let room { BoundedScroll(maxHeight: room) { fields } } else { fields }' Sources/Petal/VaultViews.swift \
    && grep -q 'if let room { BoundedScroll(maxHeight: room) { words } } else { words }' Sources/Petal/Popups.swift \
    && grep -q 'controls: max(controlsHeight, 40)' Sources/Petal/NoteViews.swift \
    || { echo "forms: buttons must stay outside the scroll, and the paper keep their room"; exit 1; }
echo "forms: fields scroll, buttons stay on the screen"
# A second opinion is part of its primary run: every outcome of it (an answer, objections, a failure, a stop) is its
# own opinion only, applied onto the note's ink as it is when it lands (never ink it captured), with the answer it
# reviewed. A reviewer outside a worktree is bound to the note's place like any run.
perl -0777 -ne '
    unless (/run\.reviewed = ""/ && /if let reviewed = run\.reviewed \{ return NoteHelp\.Result\(opinion: ink, reviewed: reviewed, steps: steps, helper: helper\) \}/
            && !/withOpinion|run\.carried|carried:/ && /run\.reviewed = NoteHelp\.inkHash\(primary\)\s*raw\.answer = primary\?\.text/
            && /let model = asked\?\.model \?\? run\.holes.*?self\.secondOpinion\(paper, model, asked: words, tree: run\.tree\)/s
            && /folder: tree, placed: tree == nil\)\)/ && /where run\.launch != nil && run\.kind\.placed/ && /= run\.kind\.placed \? NoteHelp\.requirement\(/
            && /if run\.kind\.placed, let required = run\.requiredPlace \{/) { print "NoteHelpers: a second opinion must add only its own opinion and be bound to its place\n"; exit 1 }
    for my $f (qw(fail stopped)) { unless (/func $f\([^\n]*end\(run, \./) { print "NoteHelpers: $f must end through end\n"; exit 1 } }
    print "helpers: second opinions add only their own opinion, failures included; reviewers bound to their place\n";
' Sources/Petal/NoteHelpers.swift
perl -0777 -ne '
    unless (/func apply\(to file: inout NoteFile\) \{\s*if let ink \{ file\.ink = \[ink\] \}\s*for opinion in opinions \{ file\.ink = file\.ink\.filter \{ !\(\$0\.opinion && \$0\.who == opinion\.who\) \} \+ \[opinion\] \}/
            && /init\(opinion ink: Ink\?, reviewed: String,/ && !/withOpinion/) { print "NoteHelp: a reviewer result is only its own opinion, applied onto the ink there\n"; exit 1 }
    print "helpers: a reviewer result never holds the primary ink\n";
' Sources/Petal/NoteHelp.swift
# Return runs a line only as the person wrote or edited it: the editor hands only a runnable line (its identity, a
# mark set by the person's own typing or pasting; undo, redo, autocorrect and text from outside clear it, never set
# it), and nothing about its words is kept. A bare @Petal and a note whose id isn't lasting are refused or waited on
# before the line is taken or any run registered; control requests come before follow-up routing; a follow-up's line
# goes with it through delivery; an empty prompt never reaches an agent.
perl -0777 -ne '
    unless (/func returned\(_ key: String, line: String, at ticket: NoteLine\) \{.*?if NoteHelp\.bare\(trimmed\) \{ return reply\(noteID, giveBack: nil\) \{ _ in NoteHelp\.bareHint.*?guard NoteShelf\.lasting\(noteID, pending: desk\.store\.pendingIDs\) else \{\s*return desk\.store\.ensureID\(.*?ticket\.take\(\).*?if NoteHelp\.isControl\(request\) \{ return control\(.*?NoteHelp\.followUpTarget\(/s
            && /func start\(.*?guard !words\.text\.trimmingCharacters/s && /func letGo\(.*?run\.line\?\.again\(\)/s
            && /followUps\.add\(trimmed, note: noteID, token: run\.token, line: ticket\)/ && /followUp\(run, next\.text, line: next\.line\)/
            && /private func followUp\(_ run: Run, _ words: String, line: NoteLine\?\) \{\s*if let line \{ run\.line = line \}/) {
        print "NoteHelpers: Return must take only the editor'"'"'s runnable line, after the bare and id checks, with control requests before follow-ups and follow-up lines carried\n"; exit 1 }
    if (/func returned\(.*?ticket\.take\(\)/s && $& =~ /begin\(|ask\(paper|followUps\.add/) { print "NoteHelpers: something runs before the line is taken\n"; exit 1 }
    if (/DirtyLines|\.answered\b|receipt|Helper\?\?/) { print "NoteHelpers: no text history, no receipts, no double optional for the helper line\n"; exit 1 }
    print "helpers: Return takes only the runnable line; control requests never become follow-ups; follow-up lines carried\n";
' Sources/Petal/NoteHelpers.swift
perl -0777 -ne '
    unless (/let person = !history\.isUndoing && !history\.isRedoing && !correcting/ && /override func handleTextCheckingResults\(.*?correcting = true/s
            && /private func remark\(.*?NoteHelp\.editedLines\(after: text, location: edit\.location, inserted: edit\.inserted, person: edit\.person\).*?storage\.removeAttribute\(NoteLine\.key, range: line\)\s*guard marks/s
            && /func replaceFromOutside\(_ text: NSAttributedString\) \{\s*textStorage\?\.setAttributedString\(text\)\s*\/\/[^\n]*\n\s*runnable\.removeAll\(\)/) {
        print "NoteEditor: only the person'"'"'s own typing or pasting may make a line runnable\n"; exit 1 }
    print "helpers: lines are runnable by identity, only from the person'"'"'s own edits\n";
' Sources/Petal/NoteEditor.swift
grep -q 'runnableLine(NSRange' Sources/Petal/NoteMentions.swift || { echo "NoteMentions: Return hands only a runnable line"; exit 1; }
if grep -n '"answered"' Sources/Petal/NoteHelp.swift; then echo "NoteHelp: the answered key is gone"; exit 1; fi
# Quick calls check a named AI and go through the gate when they start; a second opinion in a worktree is checked first.
perl -0777 -ne '
    my $quick = () = /guard let provider = quickProviderOrFail\(run\) else \{ return \}/g;
    my $gated = () = /app\.brain\.ask\(key: key, token: run\.token, provider: provider, gate: quickGate\(run\), make:/g;
    my $asks = () = /brain\.ask\(/g;
    unless ($quick == 2 && $gated == 1 && $asks == 1 && /func quickGate\(.*?switch self\.admit\(run\)/s && /Self\.verifyTree\(stored, noteID: paper\.noteID, token: run\.token\)/
            && /NoteHelp\.reviewTreeOK\(/) { print "NoteHelpers: quick calls must check their AI and gate; reviewers their worktree\n"; exit 1 }
    print "helpers: quick calls check their AI and pass the gate; reviewers check their worktree\n";
' Sources/Petal/NoteHelpers.swift
# Every worktree removal goes through the one ownership check (where it belongs, that checkout's, on the saved branch).
perl -0777 -ne '
    my $removes = () = /"worktree", "remove"/g;
    unless ($removes == 1 && /let check = Self\.ownedTree\(tree, noteID: noteID, token: token\)\s*let gone: \(status: Int32, output: String\)\? = if case \.owned\(let path, let checkout\) = check \{ Self\.git\(checkout, \["worktree", "remove", path\], token: token\)/
            && /func verifyTree\(.*?ownedTree\(stored/s) { print "NoteHelpers: every worktree removal goes through ownedTree\n"; exit 1 }
    print "helpers: worktrees removed only once checked to be the note'"'"'s own\n";
' Sources/Petal/NoteHelpers.swift
# A quick call uses its own AI: chosen first (the one named, else the chat'"'"'s), then checked ready.
perl -0777 -ne '
    unless (/guard let provider = named \?\? app\.chatProvider else \{ return \.none \}.*?return app\.aiReady\(provider\) \? \.go\(provider\) : \.none/s && !/aiReady\(chat\)/) {
        print "Brain: each call picks its own AI before checking it is ready\n"; exit 1 }
    print "brain: each call picks its own AI first\n";
' Sources/Petal/Brain.swift
# Only a run that succeeded writes `done` (what chains and morning notes wait for), inside `end` once its token
# completed; every other reply is a word on the note that leaves its ink and helper line as they are.
perl -0777 -ne '
    my $done = () = /state: \.done/g;
    unless ($done == 1 && /private func complete\(_ run: Run, made:.*?run\.token\.complete\(\.succeeded\).*?state: \.done/s
            && /private func reply\(_ noteID: String, giveBack line: NoteLine\?.*?\{\s*line\?\.again\(\)\s*let keep = line != nil\s*guard !parts\.isEmpty else \{ return hint\(noteID, words\(\[\]\), keep: keep\) \}/s) {
        print "NoteHelpers: only a succeeded run writes done; replies are words on the note\n"; exit 1 }
    print "helpers: only a succeeded run writes done; replies are faint\n";
' Sources/Petal/NoteHelpers.swift
# A second opinion goes through the same checkout choice as a primary request, and one asked while a run works rides
# with its line (the same queue as follow-ups: given back if that run doesn't succeed, held by the reviewer until it does).
perl -0777 -ne '
    unless (/private func review\(.*?NoteHelp\.reviewCheckout\(current: current, words: asked.*?followUps\.addReview\(model, asked: asked, note: paper\.noteID, token: run\.token, line: taking\)/s
            && /let settled = followUps\.settle\(note: noteID, token: run\.token, succeeded: !paused\).*?let asked = settled\.review.*?let line = asked\?\.line.*?self\.taking = line/s) {
        print "NoteHelpers: reviews choose their checkout and carry their line\n"; exit 1 }
    print "helpers: reviews choose their checkout like a request and carry their line\n";
' Sources/Petal/NoteHelpers.swift
# One end for every run kind: only `end` completes a run's token (and `halt`, which only `end` and a run begun again
# use), only `release` takes one out of `runs` or the looks; success hands on what was asked of it. One reply that
# isn't a run's end (`reply`, a faint word): no `say`, no `refuse`, nothing else shows a hint.
perl -0777 -ne '
    my @completes = /(\w+)\(_ run: Run[^)]*\) \{(?:(?!\n    \}).)*?token\.complete\(/sg;
    my $direct = () = /token\.complete\(/g;
    my $nil = () = /runs\[[^\]]*\] = nil/g;
    my $hints = () = /(?<!\.)\bhint\(/g;
    unless ($direct == 3 && $nil == 1 && /private func complete\(_ run: Run, made:.*?let next = handOn\(run, paused: paused\)/s && /let settled = followUps\.settle\(note: noteID, token: run\.token, succeeded: !paused\)\s*for line in settled\.dropped \{ line\.again\(\) \}\s*guard !paused else \{ return nil \}/
            && /private func release\(_ run: Run\) \{\s*if runs\[run\.noteID\] === run \{\s*runs\[run\.noteID\] = nil/
            && !/func say\(|func refuse\(|func succeeded\(|func answer\(|desk\.tell\(/ && $hints == 2
            && /self\.end\(run, \.succeeded\(nil, Made\(calc: calc\)\)\)/ && /self\.end\(run, \.succeeded\(Said\(who: who, text: line \?\? plain, form: \.words\), Made\(task: items\)\)\)/
            && /self\.end\(run, \.succeeded\(said\)\)|end\(run, \.succeeded\(said\)\)/
            && /run\.kind == \.quick \{\s*return reply\(paper\.noteID, giveBack: taking\) \{ _ in "Wait for this to finish/) {
        print "NoteHelpers: every run kind must end through end, every reply through reply ($direct completes, $nil removals, $hints hints)\n"; exit 1 }
    print "helpers: one end for every run kind, one reply\n";
' Sources/Petal/NoteHelpers.swift
# What a helper is told comes from whole sources: nothing cut or parsed out of note text before it's shielded.
perl -ne '
    if (/\braw\.\w+ = / && /spoken\(|\.values\(|prefix\(|components\(|watchWords|chainWords|lastPathComponent|suffix\(/) { print "NoteHelpers:$.: cut before shielding: $_"; $bad++ }
    $raw++ if /var titles: \[String\] = \[\]/;
    END { exit 1 if $bad || !$raw; print "helpers: only whole sources are shielded; what is needed is derived after\n" }
' Sources/Petal/NoteHelpers.swift
grep -q 'Told(ask: shown\[0\].spoken' Sources/Petal/NoteHelpers.swift && grep -q 't.body.rows.map' Sources/Petal/NoteHelp.swift \
    && grep -q 'guard let words = told.ask.watch else' Sources/Petal/NoteHelpers.swift && grep -q 'guard let ask = told.ask.chainAsk else' Sources/Petal/NoteHelpers.swift \
    && grep -q 'run.checkout = checkout' Sources/Petal/NoteHelpers.swift \
    || { echo "NoteHelpers: derivations after redaction, and a reviewer keeping its checkout"; exit 1; }
# The quick queue never calls back inside a pass: each call is out of the queue first, what's dropped is answered
# later (async), and asking it again is async too; `end` runs once per token; a gate never ends a run in a pass.
perl -0777 -ne '
    unless (/let step = queue\.pass \{/ && /for entry in step\.dropped \{ DispatchQueue\.main\.async \{ entry\.job\.done\(nil\) \} \}/
            && /func resume\(\) \{ DispatchQueue\.main\.async/ && !/queue\.removeAll|for job in queue/) { print "Brain: the quick queue must take calls out first and never call back inside a pass\n"; exit 1 }
    print "brain: calls out of the queue first, answered outside the pass\n";
' Sources/Petal/Brain.swift
perl -0777 -ne '
    unless (/private func end\(_ run: Run, _ ending: Ending\) \{.*?guard run\.token\.completion == nil, /s
            && /case \.fail\(let reason\):\s*DispatchQueue\.main\.async \{ MainActor\.assumeIsolated \{ self\.fail\(run/s) {
        print "NoteHelpers: end once per token; a quick gate never ends a run inside a pass\n"; exit 1 }
    print "helpers: end runs once per token\n";
' Sources/Petal/NoteHelpers.swift
# A watcher's results never touch the ink or the helper line: its own kind of journal output (only `watch`), `hit`
# kept only once the person was shown it; no ink, no faint word from a look.
perl -0777 -ne '
    unless (/self\.keepWatch\(noteID\) \{ current in\s*newly\.value = NoteHelp\.applyLook\(/s && /never writes ink or the helper line \(its output is its .watch., .keepWatch.\)\.\s*guard !look else \{ return \}/s
            && /private func tellHit\(.*?NoteHelp\.delivered\(watch, amount: amount.*?NoteHelp\.told\(&watch, id: watchID\)/s
            && !/not confirmed\./ && !/reply\?\["say"\]/) { print "NoteHelpers: a watcher writes only its watch, its hit kept once told\n"; exit 1 }
    print "helpers: a watcher writes only its own watch fields\n";
' Sources/Petal/NoteHelpers.swift
# Anything said of a note (a prompt, ink, a reply, a step, a chip) comes from Shielded whole sources: replies take
# only Shielded words; no title, file name or label is cut from raw text into what's said (only two raw title uses
# remain: finding a note by its name, and the @ menu'"'"'s names, both local).
perl -0777 -ne '
    my $titles = () = /file\.title/g;
    unless ($titles == 2 && /private func reply\(_ noteID: String, giveBack line: NoteLine\?, _ parts: \[String\] = \[\], _ words: \@escaping \@MainActor \(\[Shielded\]\) -> Shielded\)/
            && /private func hint\(_ noteID: String, _ words: Shielded, keep: Bool = false\)/ && !/\.label\(\)/ && !/label\.prefix|prefix\(48\)|prefix\(30\)/) {
        print "NoteHelpers: what is said of a note comes only from Shielded whole sources ($titles raw titles)\n"; exit 1 }
    print "helpers: replies, steps and chips only from Shielded whole sources\n";
' Sources/Petal/NoteHelpers.swift
! grep -n 'paper\.file\.title' Sources/Petal/NoteTools.swift || { echo "NoteTools: chips take titles derived after redaction"; exit 1; }
grep -q 'This note.s place isn.t in front: Petal is waiting for it' Sources/Petal/StickyNotes.swift && ! grep -n 'waitingFor:' Sources/Petal/StickyNotes.swift \
    || { echo "StickyNotes: a helper waiting is never told its place by name"; exit 1; }
# A reviewer is registered before its AI is checked: every way it can't go ends through end (its line given back).
perl -0777 -ne '
    unless (/private func secondOpinion\(.*?let run = begin\(paper, asked: asked.*?guard case \.use\(let id\) = provider\(for: model\).*?return fail\(run,/s) {
        print "NoteHelpers: a reviewer is registered before its AI is checked\n"; exit 1 }
    print "helpers: a reviewer ends through end, its AI checked after it holds its line\n";
' Sources/Petal/NoteHelpers.swift
# Keyword routing never does anything destructive by itself: the routes found by a phrase act only on a plain
# instruction, and removing a worktree from words asks first (a card, Don't the default); only Remove, or a merged
# pull request, removes it.
perl -0777 -ne '
    unless (/static func request\(_ line: String, now: Date, calendar: Calendar = \.current\) -> Request \{.*?let route = candidate\(line, now: now, calendar: calendar\)\s*if case \.ask = route \{ return route \}\s*return imperative\(instruction\(route, line: line, words: words\)\) \? route : \.ask\(words\)/s
            && !/if plain, /) { print "NoteHelp: every local route passes one gate\n"; exit 1 }
    print "helpers: every local route passes one gate (questions, conditions, negations go to the helper)\n";
' Sources/Petal/NoteHelp.swift
perl -0777 -ne '
    unless (/case \.done where paper\.file\.worktree != nil: askToRemoveWorktree\(paper, asked: trimmed\)/
            && /private func askToRemoveWorktree\(.*?app\.assist\.ask\("remove:" \+ noteID, "Remove the worktree for .*?warn: true, allow: "Remove".*?guard allowed else \{ return left\(.*?self\.removeWorktree\(paper, why: "you said it.s done", token: token\)/s
            && /self\.removeWorktree\(paper, why: "its pull request merged"/ && !/request\.kind\.hasPrefix\("remove:"\) \{ stamp/) {
        print "NoteHelpers: a worktree is removed from words only after Remove on its card\n"; exit 1 }
    print "helpers: a worktree is removed from words only after Remove\n";
' Sources/Petal/NoteHelpers.swift
# A chain's predecessor is a source of its run: checked by its id and current notebook when the chain is made and when
# it fires, and by the gate before anything goes.
perl -0777 -ne '
    unless (/guard mayRead\(first\.notebook, from: target\) else/ && /private func fire\(.*?guard let first = self\.paper\(chain\.after\), mayRead\(first\.notebook, from: paper\) else.*?run\.sources = \[first\.noteID\].*?guard let first = self\.paper\(chain\.after\), self\.mayRead\(first\.notebook, from: now\) else/s) {
        print "NoteHelpers: a chain checks its predecessor as a source\n"; exit 1 }
    print "helpers: a chain checks its predecessor as a source\n";
' Sources/Petal/NoteHelpers.swift
# A watcher decides on its exact value, shows it on every face with a corner, and is acknowledged only once seen.
grep -q 'let value = current.amount, crossed(value, line: current.line)' Sources/Petal/NoteHelp.swift \
    && grep -q 'NoteHelp.delivered(watch, amount: amount, cornerShowing: self.desk?.isShowingCorner(paper.key) == true)' Sources/Petal/NoteHelpers.swift \
    && perl -0777 -ne 'exit(/private var openBody: some View \{\s*watchCorner/ ? 0 : 1)' Sources/Petal/NoteViews.swift \
    || { echo "watchers: exact values, the corner on the open paper, delivery once seen"; exit 1; }
echo "helpers: watchers decide on exact values and are told on any face with the corner"
# Everything a helper produces is shielded whole as it arrives (answers, steps, opinions, proof, links, errors, a
# quick call's line, a watcher's words, a formula, a stamp's label): ink can only be made from Shielded, steps go on
# only as Shielded; while the vault can't be read nothing is held (the run fails); stamps keep an opaque rules id.
perl -0777 -ne '
    unless (/init\(who: String, text: Shielded, proof: \[Shielded\] = \[\], link: Shielded = "",/ && /private init\(stored who: String/
            && /static func codeInk\(who: String, answer: Shielded, finish: Shielded\?\)/ && /static func rulesGrant\(.*?hash8\(/s
            && /static func shielded\(_ said: Said, index: UIMap\.SecretIndex\)/) { print "NoteHelp: ink only from Shielded; stamps keep an opaque id\n"; exit 1 }
    print "helpers: ink only from Shielded; rules never in a stamp\n";
' Sources/Petal/NoteHelp.swift
perl -0777 -ne '
    unless (/private func result\(_ run: Run, ink: NoteHelp\.Ink\?, steps: \[Shielded\]\? = nil,/
            && /case \.succeeded\(let said, let also\):.*?Self\.shieldSaid\(said\) \{ made in.*?guard let made else \{ return self\.end\(run, \.failed\(Self\.vaultWords\.text\)\) \}.*?self\.complete\(run, made: made, also\)/s
            && /private func turnOutput\(.*?guard let made else \{ return self\.end\(run, \.failed\(Self\.vaultWords\.text\)\) \}/s
            && /case \.failed\(let reason, let settings\):.*?failureOutput\(run, Said\(/s && /turnOutput\(run, Said\(who: run\.who, text: answer, steps: steps/
            && /private func stamp\(.*?Self\.shield\(\[label\]\)/s && /grantedRules\[grant\] = rules/ && /Self\.shield\(\[calc\.formula, calc\.label\]\)/
            && /Self\.shield\(\[reply\?\["before"\]/) {
        print "NoteHelpers: every helper output is shielded whole as it arrives\n"; exit 1 }
    # Fail, do not hold: nothing kept unshown, no retry; a leftover file of an earlier Petal deleted, locally.
    if (/waitingForVault|showUnshown|holdForVault|saveUnshown|Unshown\(/) { print "NoteHelpers: nothing is held unshown\n"; exit 1 }
    unless (/NoteJournal\.queue\.async \{ try\? FileManager\.default\.removeItem\(at: leftover\) \}/ && /leftoverUnshown: URL \{ NoteJournal\.folder\.appending/) {
        print "NoteHelpers: a leftover held file is deleted on launch\n"; exit 1 }
    # A run starts only when the vault is readable: a line (before it is taken) and a chain (before it fires).
    unless (/func returned\(.*?Self\.vaultReady \{ ready in\s*guard ready else \{ return self\.reply\(noteID, giveBack: nil\) \{ _ in Self\.vaultWords \} \}.*?self\.take\(paper, trimmed, at: ticket\)/s
            && /private func take\(_ paper: PaperNote, _ trimmed: String, at ticket: NoteLine\) \{\s*let noteID = paper\.noteID\s*ticket\.take\(\)/
            && /private func fire\(.*?Self\.vaultReady \{ ready in.*?self\.fireNow\(paper\)/s && /func vaultLost\(_ sticky: StickyNote\) \{.*?end\(run, \.failed\(Self\.vaultWords\.text\)\)/s) {
        print "NoteHelpers: a run starts only with the vault readable; output while it is not fails the run\n"; exit 1 }
    print "helpers: every output shielded as it arrives; fail, never hold; nothing starts while the vault can.t be read\n";
' Sources/Petal/NoteHelpers.swift
! grep -rn 'Unshown\|helper-unshown' Sources/Petal/NoteHelp.swift || { echo "NoteHelp: nothing is held unshown"; exit 1; }
# The agent's boundary, for a helper (a note's run) only: every provider event shielded in order on its own queue
# before anything reads it, and one the vault can't shield fails its run. An ordinary chat's events and its end go
# straight to the main thread, never through that queue or a vault read; its activity (shown outside its panel) and
# an action's caption are shielded where they're made, with no wait and no hop (the index already made, else
# "Working…"); a caption carries its turn.
perl -0777 -ne '
    unless (/var activity: Shielded = ""/ && /AgentIngest\.deliver\(lines, helper: helper, queue: ingest, parse: \{ \$0\.flatMap \{ provider\.events\(\$0\) \} \}, shield: Agent\.shield\) \{ shown in/
            && /guard let shown else \{ return self\.vaultLost\(\) \}\s*for \(event, words\) in shown \{ self\.apply\(event, words: words\) \}/
            && /AgentIngest\.after\(helper: helper, queue: ingest\) \{/ && !/ingest\.async/ && /nonisolated static func shield\(_ events: \[Event\]\) -> /
            && /activity = words \?\? Self\.shown\(text\)/ && /static func shown\(_ text: String\) -> Shielded \{\s*let index = VaultIndex\.cached\(\)\s*if index == nil \{ VaultIndex\.warm\(\) \}\s*return NoteShield\.now\(text, index: index\)/
            && /func caption\(_ text: String, turn: Int\) \{\s*guard turn == self\.turn, running else \{ return \}\s*activity = Self\.shown\(text\)/) {
        print "Agent: a helper is shielded at the boundary; a chat never waits on the vault\n"; exit 1 }
    my $calls = () = /Agent\.shield\(/g;
    my $reads = () = /VaultIndex\.(settled|current|stamped)\(|VaultIndex\.settled \{/g;
    if ($calls != 0 || $reads != 1) { print "Agent: only a helper ingestion reads the vault ($calls, $reads)\n"; exit 1 }
    print "agent: a helper shielded at the boundary; an ordinary chat delivered as on main, its shown lines shielded with no wait\n";
' Sources/Petal/Claude.swift
perl -0777 -ne '
    unless (/enum AgentIngest \{.*?guard helper else \{\s*DispatchQueue\.main\.async \{ MainActor\.assumeIsolated \{ apply\(parse\(lines\)\.map \{ \(\$0, nil\) \}\) \} \}\s*return/s) {
        print "AgentIngest: a chat goes straight to the main thread\n"; exit 1 }
' Sources/Petal/NoteHelp.swift
grep -q 'agent.caption(job.caption, turn: agent.turn)' Sources/Petal/ComputerUse.swift && ! grep -n 'NoteHelpers.shield(\[job.caption\])' Sources/Petal/ComputerUse.swift \
    || { echo "ComputerUse: its caption is shielded where it is made, for its turn, with no hop"; exit 1; }
# Round eighteen, A: every paid call starts through one function. What waits is the call (its sources), never words:
# a helper agent turn that waits keeps only a mark, the quick line keeps how the words are made, a follow-up waits as
# the line the person wrote; `prepare` runs the one launch order (NoteHelp.launch); recalculate and put away go through
# it with the note and its cover (no empty Raw); a file is routed by the git repository it is really in.
perl -0777 -ne '
    unless (/private func prepare\(_ run: Run, _ call: Call, _ then:.*?let steps = NoteHelp\.LaunchSteps<Raw, NoteHelp\.Told, Shielded>\(.*?vault: \{ ready in Self\.vaultReady.*?sources: \{ read in self\.gather\(run, call\).*?return self\.admit\(run\).*?Self\.tell\(raw\) \{ told, stamp in.*?VaultIndex\.unchanged\(since: stamp\).*?NoteHelp\.launch\(steps\)/s
            && /private func gather\(.*?var raw = raw\(paper\)\s*if let problem = call\.sources\(paper, &raw\).*?switch coverChoice\(of: notebook\)/s
            && !/var held: Shielded/ && !/private func told\(/ && !/private func deliver\(/ && !/private func (recalculate|putAway)\((?:(?!\n    \}\n).)*?Raw\(\)/s
            && /private func recalculate\((?:(?!\n    \}\n).)*?start\(run, Call\(sources:/s && /private func putAway\((?:(?!\n    \}\n).)*?self\.start\(run, Call\(sources: sources/s
            && /self\.start\(run, Call\(sources: sources, words: \{ told in/ && /start\(run, Call\(sources: sources, words: \{ NoteHelp\.watchFind\(\$0\) \}/
            && /return Self\.repository\(holding: stick, mac: mac\) \{ found in/ && /AgentAccess\.repository\(folder, files: AgentCallers\.disk\)/ && !/NoteHelp\.checkout\(holding:/) {
        print "NoteHelpers: every paid call starts through start, built at launch from its sources\n"; exit 1 }
    print "helpers: one start for every paid call; what waits is its sources, its words made at launch\n";
' Sources/Petal/NoteHelpers.swift
perl -0777 -ne '
    unless (/private func holdTurn\(\) \{.*?waiting = \[Self\.helperTurn\]/s && /if helperSystem != nil \{ again\?\(\); return \}/ && /case \.wait, \.rebuild: return holdTurn\(\)/
            && /if helperSystem != nil \{ return holdTurn\(\) \}/ && /guard admitted else \{ if helperSystem != nil \{ return holdTurn\(\) \}/
            && /if helperSystem == nil \{ messages\.append\(Message\(kind: \.user, text: prompt\)\) \}/) { print "Agent: a helper turn that waits keeps no words\n"; exit 1 }
    print "agent: a helper turn that waits keeps only the wait\n";
' Sources/Petal/Claude.swift
perl -0777 -ne '
    unless (/case made\(\(\@escaping \@MainActor \(Made\) -> Void\) -> Void\)/ && /func ask\(key: String, token: RunToken, provider: Provider\? = nil, gate: \(\(\) -> Bool\)\? = nil,\s*make:/
            && !/func ask\(_ prompt: Shielded/ && /case \.wait:.*?self\.queue\.putBack\(entry\)/s) { print "Brain: a helper call waits as how it is made, never as words\n"; exit 1 }
    print "brain: a helper call is made when its turn comes\n";
' Sources/Petal/Brain.swift
grep -q 'enum Item { case say(String), review(NoteHelp.Model, asked: String) }' Sources/Petal/NoteHelp.swift || { echo "FollowUpQueue: a follow-up waits as the line the person wrote"; exit 1; }
# B: a result lands only after the gate is asked again, on the main actor, right before; a finished answer lands
# paused or not (a paused run hands nothing on); a result held through a conflict is asked about again when applied.
perl -0777 -ne '
    unless (/private func complete\(_ run: Run, made:(?:(?!\n    \}\n).)*?if !look, let refused = landing\(run\) \{ return end\(run, \.failed\(refused\)\) \}\s*let paused = run\.token\.paused\s*guard run\.token\.complete\(\.succeeded\) else \{ return \}(?:(?!\n    \}\n).)*?keep\(run, result\(run, ink: made\?\.ink, steps: made\?\.steps, also: also, helper: \.set\(done\)\)\)/s
            && /private func landing\(_ run: Run\) -> String\? \{\s*switch admit\(run, landing: true\)/
            && /private func turnOutput\((?:(?!\n    \}\n).)*?if let refused = self\.landing\(run\) \{ return self\.end\(run, \.failed\(refused\)\) \}\s*self\.keep\(/s
            && /if entry\.of == \.answer, let refused = heldRefusal\(entry, on: papers\[0\]\)/ && /facts\.landing = landing/) {
        print "NoteHelpers: a result lands as one value, after the gate, paused or not\n"; exit 1 }
    print "helpers: one result per run, through the gate right before it lands\n";
' Sources/Petal/NoteHelpers.swift
# C: the one place a token changes state ends its actions in apps first (pause, cancel and every completion), and
# nothing else sets its state but Go on; the helpers bind that to ComputerUse, whose session for a helper is bound to
# the run token itself.
perl -0777 -ne '
    my $first = () = /let actions = _actions\s*lock\.unlock\(\)\s*(?:\/\/[^\n]*\n\s*)?actions\?\(\)\s*for each in stop \{ each\(\) \}/g;
    my $sets = () = /\b_state = /g;
    unless ($first == 2 && $sets == 3 && /func pause\(\) -> Bool \{ transition\(/ && /func cancel\(\) -> Bool \{ transition\(/
            && /if completion == \.succeeded, _state != \.running, _state != \.paused \{/) { print "RunToken: every state change ends its actions first ($first, $sets)\n"; exit 1 }
    print "run token: every change of state ends its actions in apps first\n";
' Sources/Petal/NoteHelp.swift
perl -0777 -ne '
    unless (/private func bindActions\(_ run: Run\) \{\s*run\.token\.actions \{/ && /app\.assist\.computer\.end\(caller\)/
            && /let run = Run\(token: tokens\.start\(paper\.noteID\), noteID: paper\.noteID, asked: asked, who: who\)\s*bindActions\(run\)/) {
        print "NoteHelpers: a run binds its actions in apps to its token\n"; exit 1 }
' Sources/Petal/NoteHelpers.swift
grep -q 'cancel = Acting.Cancel(run: run)' Sources/Petal/ComputerUse.swift \
    && grep -q 'var made = Session(turn: turn, run: app.claude.note(withID: caller)?.agent.token)' Sources/Petal/ComputerUse.swift \
    || { echo "ComputerUse: a helper reply is bound to its run token"; exit 1; }
echo "helpers: pause, park, stop and end all end the run's actions in apps; every action is bound to its token"
grep -q 'if let watch = paper.file.watch, NoteHelp.corner(watch) != nil' Sources/Petal/NoteViews.swift && grep -q 'NoteHelp.corner(paper.file.watch) == nil ? 0 : 44' Sources/Petal/NoteViews.swift \
    || { echo "watchers: the corner is drawn, and its room kept, when either value is there"; exit 1; }
# A watcher decides on its exact value: a refuted or unconfirmed reading never becomes the shown value; nothing about
# its value is rounded but the drawing.
! grep -n 'Int(\$0.rounded())' Sources/Petal/NoteHelpers.swift && grep -q 'guard let shown, verdict != .refuted, verdict != .unconfirmed else' Sources/Petal/NoteHelp.swift \
    && grep -q 'if let faint = corner?.faint' Sources/Petal/NoteHelpViews.swift && grep -q 'current.unconfirmed = verdict == .unconfirmed ? (shown ?? "") : ""' Sources/Petal/NoteHelp.swift \
    && grep -q 'if newly.value, let value { self.tellHit' Sources/Petal/NoteHelpers.swift || { echo "watchers: exact values; rejected readings never shown; an unconfirmed crossing faint, never opening the note"; exit 1; }
echo "helpers: rejected readings keep the last accepted value; only drawing rounds"
# A cover that can't be read yet is waited for (iCloud asked), then refused; never skipped.
perl -0777 -ne '
    unless (/private func gather\(.*?case \.notHere, \.conflict:\s*guard waited < Self\.coverWait else \{\s*if !run\.kind\.apart \{ reply\(.*?Couldn.t read .*?cover yet.*?end\(run, \.stopped\(nil\)\)\s*return done\(\.refused\)/s
            && /raw\.coverOf = / && !/raw\.cover = mayRead/) { print "NoteHelpers: a cover that can.t be read is waited for, then refused\n"; exit 1 }
    print "helpers: an unreadable cover is waited for, then refused, never skipped\n";
' Sources/Petal/NoteHelpers.swift
# The reading lens (a margin note in Petal's viewer following the selection) is a paid call like any other: it asks
# only through `start` (so the vault, the gate and the shielded prompt come first), one call at a time per note (a
# newer selection ends the one before), its answer shielded whole before it's shown, and nothing of it written on
# the note (a run apart, like a watcher's look). The viewer asks nobody else, and closing it turns the lens off.
# (Petal --helpers-check drives it, step 14; this keeps its shape in the source.)
perl -0777 -ne '
    unless (/func lens\(_ request: ViewerLensRequest, _ answer: [^\n]*\{\s*lensOff\(request\.noteID\)/
            && /made\.kind = \.lens.*?start\(made, Call\(sources: .*?words: \{ NoteHelp\.lensAsk\(\$0\) \}, to: \.quick\(key: "lens\|.*?Self\.shield\(\[words\]\) \{ shown in/s
            && /var apart: Bool \{ self == \.look \|\| self == \.lens \}/ && /func lensOff\(_ noteID: String\) \{\s*if let old = lensAt\[noteID\] \{ end\(old, \.stopped\(nil\)\) \}/) {
        print "NoteHelpers: the reading lens asks through start, one call per note, its answer shielded\n"; exit 1 }
    print "helpers: the reading lens is a paid call through start, its answer shielded, nothing written on the note\n";
' Sources/Petal/NoteHelpers.swift
perl -0777 -ne '
    my $asks = () = /helpers\.lens\(/g;
    unless ($asks == 1 && /private func askLens\(_ request: ViewerLensRequest\) \{\s*lensRequest = request\s*if let onLens \{ return onLens\(request\) \}/
            && /lensSoon\?\.cancel\(\)\s*(?:\/\/[^\n]*\n\s*)*follow\(nil\)/ && /DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ 0\.6, execute: work\)/) {
        print "Viewer: the lens asks only the note helpers, once the selection settled, and goes off when the viewer closes\n"; exit 1 }
    print "viewer: the lens asks once a selection settles, through the helpers, and is off when the viewer closes\n";
' Sources/Petal/Viewer.swift
grep -q 'static func lensAsk(_ t: Told) -> Shielded?' Sources/Petal/NoteHelp.swift || { echo "NoteHelp: the lens words are made only from what was shielded"; exit 1; }
# Every reviewer output, its turns on the way included, goes through its one result (an opinion).
perl -0777 -ne '
    if (/Something said meanwhile.*?\n\s*return\n/s && $& !~ /turnOutput\(run, Said\(who: run\.who, text: answer, steps: steps, form: run\.reviewed == nil \? \.answer : \.opinion\)\)/) { print "NoteHelpers: a reviewer turn must go through output\n"; exit 1 }
    print "helpers: every reviewer output goes through opinion\n";
' Sources/Petal/NoteHelpers.swift
# Helpers read and write a cover only by the cover rule (the file named for it in the notebook's own folder).
if grep -n 'file\.cover\b' Sources/Petal/NoteHelpers.swift; then echo "NoteHelpers: helpers find covers by name, never by cover: true"; exit 1; fi
[ "$(grep -c 'coverToChange(paper' Sources/Petal/NoteHelpers.swift)" -ge 4 ] || { echo "NoteHelpers: every cover change goes through coverToChange"; exit 1; }
echo "helpers: covers by the cover rule; a cover in conflict gets no memory"
swiftc -parse-as-library -O -o "$out/notestore" Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/PaperNotes.swift Sources/Petal/NoteJournal.swift checks/NoteStoreCheck.swift
"$out/notestore"
# Selection changes never read text on the main thread: PDFKit's selection string isn't read anywhere in the viewer's
# views (the words come from ViewerText's read off it).
if grep -nE '(currentSelection|selection)[?]?\.(string|attributedString)' Sources/Petal/ViewerViews.swift; then
  echo "viewer: a selection's text read on the main thread (ViewerViews.swift)"; exit 1
fi
echo "viewer: no selection text read on the main thread"
# A passage for Petal AI follows petal_look's rule for selected text (UIMap.selectionHidden), and what the note tools
# tell an agent is redacted with the vault's index, or not told while the vault can't be read (NoteShield).
swiftc -parse-as-library -O -o "$out/noteselection" Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift checks/NoteSelectionCheck.swift
"$out/noteselection"
# Petal's viewer: a file anchor's page, slide and passage, the path an agent names (on throwaway folders in the
# temporary folder), the margin's layout, a preview cut into pages, copies' names and comments (no window, no PDF).
swiftc -parse-as-library -O -o "$out/viewer" Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift Sources/Petal/ViewerFile.swift checks/ViewerFileCheck.swift
"$out/viewer"
swiftc -parse-as-library -O -o "$out/background" Sources/Petal/Background.swift Sources/Petal/UIMap.swift checks/BackgroundCheck.swift
"$out/background"
# A hidden display for each Petal AI run: who gets one and who waits, sharing, release on every ending, the limit,
# where one goes, which displays are the person's, what a run leaves behind (RunDisplayPlan; no display is ever made).
swiftc -parse-as-library -O -o "$out/rundisplay" Sources/Petal/RunDisplayPlan.swift checks/RunDisplayCheck.swift
"$out/rundisplay"
# A run's own browser: the DevTools pipe's messages cut out whole and matched to their requests, which browser a run
# gets and what it's started with, a profile folder's name and what's swept after a crash, which addresses open, how a
# page reads to an AI (ids, caps, what's hidden, as petal_ui hides it), the vault's decisions fed with what the
# browser says of a page's frames, and what goes into a page going in as a value, never as code (RunBrowserPlan,
# RunBrowserScript; no browser is ever started: Petal --browser-check does that, headless).
swiftc -parse-as-library -O -o "$out/runbrowser" Sources/Petal/RunBrowserPlan.swift Sources/Petal/RunBrowserScript.swift Sources/Petal/Vault.swift Sources/Petal/UIMap.swift checks/RunBrowserCheck.swift
"$out/runbrowser"
# A run's browser is never taken for one of the person's apps: nothing in the sources asks macOS for the running
# copies of an app by its id, or for every running app, but through the person's own lists (RunApps.swift's
# `persons(withBundleIdentifier:)` and `personsApplications`), apart from the places that mean every process: Petal's
# own copies (main, Doctor), macOS's Dock (Signals, Windows, MissionControl), the music players, the apps kept private
# (AssistMore), the events every app is listened to for (Windows), a bench, and the lists themselves.
perl -ne '
    next if $ARGV =~ m{/(RunApps|BrowserCheck|DisplayCheck|main|Signals|Windows|MissionControl|Doctor|AssistMore|Bench)\.swift$};
    if (/NSRunningApplication\.runningApplications\(withBundleIdentifier|NSWorkspace\.shared\.runningApplications/) { print "$ARGV:$.: asks for running apps without leaving out a run\x27s browser\n"; $bad = 1 }
    close ARGV if eof;
    END { exit($bad ? 1 : 0) }
' Sources/Petal/*.swift
echo "run browser: the dock, the tools and routines list only the person's own apps"
# An open through macOS never lands in a run's own browser: wherever Petal opens something in an app it names, for a
# run's display or the person's screen, a run's copy of that app going means it's opened as a new one; and what an
# open for a run's display started is asked of the rule, which never gives a run's own browser to another run.
for file in Dock RunDisplay Assist; do
    grep -Eq 'if Run(Apps|Browsers)\.running\(bundle: [a-zA-Z.]+\) \{ configuration\.createsNewApplicationInstance = true \}' "Sources/Petal/$file.swift" \
        || { echo "run browser: $file.swift opens in an app without opening a new copy while a run has its own going"; exit 1; }
done
grep -q 'opened.launched = RunDisplayRules.started(' Sources/Petal/RunDisplay.swift \
    || { echo "run browser: RunDisplays.open doesn't ask RunDisplayRules.started which process it started"; exit 1; }
grep -q 'personsOnly: true' Sources/Petal/RunDisplay.swift || { echo "run browser: RunDisplays.open may take a run's own browser window for one it made"; exit 1; }
echo "run browser: an open through macOS never lands in a run's own copy"
# No page of a run's browser writes or reads the clipboard by itself, and a press is watched: the browser is told
# what's refused (RunBrowserRules.refused) before its first tab, and ended if it won't take it; every way a press
# reaches a page (a script run with a gesture, a key) notes the clipboard's count first and hands it to the watch.
perl -0ne '
    $bad .= "open() doesn\x27t refuse the clipboard before the first tab\n"
        unless /for permission in RunBrowserRules\.refused \{\s*guard case \.success = pipe\.call\("Browser\.setPermission", RunBrowserRules\.refusal\(permission\)\) else \{\s*return Problem.*?\n.*?Target\.createTarget/s;
    $bad .= "a script run with a gesture isn\x27t watched\n" unless /let mark = gesture \? Acting\.CopyMark\.now\(clipboard\) : nil\s*defer \{ if let mark \{ onPress\?\(mark\) \} \}\s*switch pipe\.call\("Runtime\.evaluate"/;
    $bad .= "a key isn\x27t watched\n" unless /let mark = Acting\.CopyMark\.now\(clipboard\)\s*defer \{ onPress\?\(mark\) \}\s*guard case \.success = pipe\.call\("Input\.dispatchKeyEvent"/;
    $bad .= "a press isn\x27t handed to the watch\n" unless /browser\.onPress = .*?watchCopy\(mark, browser\)/s && /Acting\.CopyWatch\.start\(mark, wait: RunBrowserRules\.copyWatch, pasteboard: clipboard/;
    @gestures = /"userGesture"|Input\.dispatch\w+/g;
    $bad .= "a press reaches a page some other way (" . scalar(@gestures) . " places)\n" unless @gestures == 3;
    END { print "run browser: $_\n" for split /\n/, $bad; exit($bad ? 1 : 0) }
' Sources/Petal/RunBrowser.swift
echo "run browser: no page writes the clipboard by itself, and a press is watched"
swiftc -parse-as-library -O -o "$out/vault" Sources/Petal/Vault.swift Sources/Petal/UIMap.swift checks/VaultCheck.swift
"$out/vault"
# What Petal AI's reads are searched with: every item's secrets, the digit codes its notes name (as secrets), and what
# reads as a code in its notes (found whole).
grep -q 'UIMap.SecretIndex(items.flatMap(Vault.secrets) + items.flatMap(Vault.noteNumbers) + extra, words: items.flatMap(Vault.noteCodes))' Sources/Petal/AssistMore.swift \
    || { echo "VaultIndex: the index holds each item's secrets and its notes' codes"; exit 1; }
swiftc -parse-as-library -O -o "$out/agents" Sources/Petal/AgentAccess.swift Sources/Petal/AgentCallers.swift checks/AgentAccessCheck.swift
"$out/agents"
# Who is Petal AI is only what the check above proved, in the app too: each chat's AI process is recorded where it
# starts, the socket says which function is asked for, a chat's id comes from that record (never from the caller's
# words), and `petal run` asks for every caller alike (no way round its card for Petal AI).
grep -qF 'AgentCallers.started(process.processIdentifier, for: noteID.uuidString)' Sources/Petal/Claude.swift \
    && grep -qF 'AgentCallers.identify(client: client, tools: words.first == "assist")' Sources/Petal/IPC.swift \
    && grep -qF 'let caller = who.note ?? "mcp-\(who.pid)"' Sources/Petal/App.swift \
    || { echo "agents: a chat is Petal's own only by Petal's record of the AI process it started"; exit 1; }
if grep -nE 'agent == \.petal|kind: \.petal|pass\(\.petal' Sources/Petal/AgentVault.swift; then echo "agents: petal run must ask for every caller, Petal's own chats too"; exit 1; fi
if grep -nE 'who\.agent == \.petal' Sources/Petal/App.swift; then echo "agents: a chat's id comes from Petal's record, never from who claims it"; exit 1; fi
echo "agents: Petal AI is only the tools of an AI Petal started; petal run always asks"
# Full access and Always cover Petal AI and the person's own Claude Code and Codex (NoteHelp.autoGrant, checked above
# with the helpers): Assist.ask works out who a question is for from its owner and what Petal read of that caller,
# makes the card NoteHelp.card says (who asks; no Always for a caller Petal can't verify), and every card a caller
# outside Petal can bring up says what it wants.
perl -0777 -ne '
    unless (/let asker = NoteHelp\.asker\(owner: owner, known: owner\.map \{ app\.claude\.note\(withID: \$0\) != nil \} \?\? false,\s*verified: owner\.flatMap \{ outside\[\$0\] \}\?\.agent\.verified \?\? false\)/
            && /NoteHelp\.autoGrant\(kind: kind, [^\n]*, asker: asker\)/
            && /let card = NoteHelp\.card\(title: title, wants: wants, every: always \|\| warn, asker: asker, label: who\?\.label\)\s*let request = Request\(kind: kind, title: card\.title, detail: detail, every: card\.every,/) {
        print "Assist.ask: who a question is for decides whether it is asked, and what its card says\n"; exit 1 }
    print "asking: Full access and Always cover Petal AI and the person\x27s own verified agents; an outside caller\x27s card says who asks\n";
' Sources/Petal/Assist.swift
perl -ne '
    next if $ARGV =~ m{/(AgentVault|VaultFill|NoteHelpers)\.swift$};   # the vault\x27s cards say who asks themselves; a helper\x27s are its own
    if (/\bask\((RunBrowsers\.kind|"(quit|close|trash|tidy|pdfComments|computer:[^"]*)"),/ && !/wants:/) { print "$ARGV:$.: a card anyone outside Petal can bring up must say what it wants (wants:)\n"; $bad = 1 }
    $seen++ if /\bask\((RunBrowsers\.kind|"(quit|close|trash|tidy|pdfComments|computer:[^"]*)"),.*wants:/;
    close ARGV if eof;
    END { exit 1 if $bad || $seen < 7; print "asking: every card an outside caller can bring up says what it wants\n" }
' Sources/Petal/*.swift
# The notes for the AI in the settings window: typing, changes made elsewhere, picks and late answers (no file).
swiftc -parse-as-library -O -o "$out/instructions" Sources/Petal/InstructionsState.swift checks/InstructionsCheck.swift
"$out/instructions"
swiftc -parse-as-library -O -o "$out/routinestop" Sources/Petal/RoutineStop.swift checks/RoutineStopCheck.swift
"$out/routinestop"
# Where routines may take files from and file them into: a folder's path as written, and where it really is once
# every link is followed (a subfolder that is a link, a named folder that leads out of the home folder or into its
# Library, a link among the files), on throwaway folders in the temporary folder; the rule only answers, nothing moves.
swiftc -parse-as-library -O -o "$out/routinerules" Sources/Petal/RoutineRules.swift checks/RoutineRulesCheck.swift
"$out/routinerules"
# A routine that opens something or runs a Shortcut is the person's to allow: Petal AI's tools reach Petal AI's card
# (kind `routine`) before one is saved, changed or run by hand (`Petal --routines-check` drives it, answering the
# card itself), and a routine's open action goes through RoutineRules.opens and NoteTasks.routine, never straight
# to whatever its text names.
perl -0777 -ne '
    my ($save) = /(    private func saveTool\(.*?\n    \}\n)/s;
    my ($run) = /(    private func runTool\(.*?\n    \}\n)/s;
    my ($allow) = /(    private func allow\(.*?\n    \}\n)/s;
    my ($open) = /(        case "open":\n            \/\/ Apps, web addresses and documents only.*?\n        case "hide":)/s;
    $bad .= "saving a routine never reaches the card\n" unless defined $save && $save =~ /guard RoutineRules\.savingAsks\(.*?else \{ return keep\(\) \}.*?self\.allow\(/s;
    $bad .= "running a routine never reaches the card\n" unless defined $run && $run =~ /guard !dry, Self\.asksFirst\(routine\) else \{.*?\n        allow\(/s;
    $bad .= "the card isn\x27t Petal AI\x27s\n" unless defined $allow && $allow =~ /assist\.ask\("routine", title, detail: detail, owner: owner, done: done\)/;
    $bad .= "open takes more than RoutineRules.opens gives\n"
        unless defined $open && $open =~ /switch RoutineRules\.opens\(item\)/ && $open =~ /NoteTasks\.routine\(file\)/ && $open !~ /URL\(string: item\)|expandingTildeInPath/;
    END { if ($bad) { print "routines: $bad"; exit 1 } print "routines: opening and Shortcuts ask on a card, and open takes only what its rule gives\n" }
' Sources/Petal/Routines.swift
# Which Petal processes are a dock: a benchmark, snapshot, the AI's tools or a command never count as a second one
# (PetalProcess; the Dock guard's shell test with pgrep and ps stood in for, never a real Petal).
swiftc -parse-as-library -O -o "$out/petalprocess" Sources/Petal/PetalProcess.swift checks/PetalProcessCheck.swift
"$out/petalprocess"
# UpdateTrust.swift: a downloaded Petal is installed only when it's signed as asked, whole. On tiny bundles the check
# makes and signs itself in the temporary folder. Then the three places that say whose signature that is (the app,
# get.sh, the release workflow) must say it in the same words: a release one of them refused would strand the others.
swiftc -parse-as-library -O -o "$out/updatetrust" Sources/Petal/UpdateTrust.swift checks/UpdateTrustCheck.swift
"$out/updatetrust"
maker=$(sed -n 's/^    static let maker = #"\(.*\)"#$/\1/p' Sources/Petal/UpdateTrust.swift)
[ -n "$maker" ] || { echo "update trust: couldn't read the maker's requirement from UpdateTrust.swift"; exit 1; }
grep -qF "MAKER='$maker'" ../get.sh || { echo "update trust: get.sh doesn't check the same signature as UpdateTrust.swift"; exit 1; }
grep -qF "MAKER: '$maker'" ../.github/workflows/release-macos.yml || { echo "update trust: the release workflow doesn't check the same signature as UpdateTrust.swift"; exit 1; }
echo "update trust: the app, get.sh and the release workflow ask for the same signature"
# The updater puts a checked update in place only through UpdateTrust.install, which looks at the bundle in place
# afterwards (the check above runs it on bundles of its own): never a bare move of what was checked a moment before.
n=$(grep -c 'replaceItemAt' Sources/Petal/Updater.swift || true)
grep -q 'guard try UpdateTrust\.install(app, in: bundle, is: release\.version, over: running) else' Sources/Petal/Updater.swift && [ "$n" = 0 ] \
    || { echo "update trust: the updater puts an update in place without looking at it there"; exit 1; }
echo "update trust: an update is looked at again once it's in place"
# WhatsNew.swift: after an update What's New opens once, with each version missed since the last one Petal ran as,
# never on a first install; and every notes file in macos/notes leaves its release-page-only lines out of the app.
swiftc -parse-as-library -O -o "$out/whatsnew" Sources/Petal/UpdateTrust.swift Sources/Petal/WhatsNew.swift checks/WhatsNewCheck.swift
"$out/whatsnew" notes
grep -q 'cp "$ROOT"/macos/notes/\*.md "$APP/Contents/Resources/notes/"' build.sh \
    || { echo "what's new: build.sh doesn't put the notes in the app"; exit 1; }
# AgentSetup.swift: turning other AI agents off takes back only Petal's own skill copy, command link and MCP
# registration (on throwaway folders: links never followed); DockImport.swift: importing macOS's Dock replaces only on
# the first setup and otherwise adds.
swiftc -parse-as-library -O -o "$out/agentsetup" Sources/Petal/AgentSetup.swift checks/AgentSetupCheck.swift
"$out/agentsetup"
swiftc -parse-as-library -O -o "$out/dockimport" Sources/Petal/DockImport.swift checks/DockImportCheck.swift
"$out/dockimport"
# An update rebuilt with the person's own changes to Petal's code takes its source from the release Petal checked:
# Personal.update asks the updater for the commit that release's own Petal.app says (Updater.source, which checks the
# download as an installed update is and reads the commit through UpdateTrust.source) and hands petal-personal that
# commit. Then petal-personal itself, on a throwaway source with a stand-in for curl: with a commit it asks for that
# commit's source and nothing else, and a version or commit that isn't plain asks for nothing.
perl -0777 -ne '
    if ($ARGV =~ /\/Personal\.swift$/) {
        my ($update) = /(static func update\(to release: Updater\.Release.*?\n    \})/s;
        $bad .= "Personal.update does not take its source from the release it checked\n"
            unless defined $update && $update =~ /let commit = try await Updater\.source\(of: release\).*\["update", "--version", version, "--commit", commit,/s;
    }
    if ($ARGV =~ /\/Updater\.swift$/) {
        my ($source) = /(static func source\(of release: Release\).*?\n    \})/s;
        $bad .= "Updater.source does not check the release as an update is\n"
            unless defined $source && $source =~ /Self\.checked\(file, release: release, running: running\).*UpdateTrust\.source\(of: app, is: release\.version, over: running\)/s;
    }
    END { if ($bad) { print "personal update: $bad"; exit 1 } print "personal update: its source is the checked release\x27s commit\n" }
' Sources/Petal/Personal.swift Sources/Petal/Updater.swift
bash checks/PersonalUpdateCheck.sh
# The keychain Petal signs the person's own builds with is unlocked only while one build is signed: locked again on
# every way out, and set to lock by itself (PersonalSigning; no `security` command is run, no keychain touched). And
# Personal.swift opens it nowhere else: every unlock, lock and setting is PersonalSigning's, and codesign is given
# the keychain only inside `withIdentity`, which is `PersonalSigning.unlocked`.
swiftc -parse-as-library -O -o "$out/personalsigning" Sources/Petal/PersonalSigning.swift checks/PersonalSigningCheck.swift
"$out/personalsigning"
n=$(grep -c 'unlock-keychain\|lock-keychain\|set-keychain-settings\|create-keychain' Sources/Petal/Personal.swift || true)
u=$(grep -c 'PersonalSigning\.unlocked(' Sources/Petal/Personal.swift || true)
k=$(grep -c '"--keychain"' Sources/Petal/Personal.swift || true)
w=$(awk '/try withIdentity \{ keychain, hash in/,/^        \}$/' Sources/Petal/Personal.swift | grep -c '"--keychain", keychain, "--sign", hash' || true)
if [ "$n" != 0 ] || [ "$u" != 1 ] || [ "$k" != 1 ] || [ "$w" != 1 ]; then echo "personal signing: the keychain is opened outside PersonalSigning.unlocked"; exit 1; fi
echo "personal signing: the keychain is open only while a build is signed"
# IPC.swift on a throwaway socket in the temporary folder (never Petal's): a request whose client hangs up first is
# never done.
swiftc -parse-as-library -O -o "$out/ipc" Sources/Petal/IPC.swift Sources/Petal/AgentAccess.swift Sources/Petal/AgentCallers.swift checks/IPCCheck.swift
"$out/ipc"
# An act's or vault call's Acting.Cancel for a caller outside Petal stops the moment its request is hung up, on any
# thread, with the main thread blocked (IPC.Pending, no socket).
swiftc -parse-as-library -O -o "$out/cancel" Sources/Petal/ActingCancel.swift Sources/Petal/IPC.swift Sources/Petal/AgentAccess.swift Sources/Petal/AgentCallers.swift checks/CancelCheck.swift
"$out/cancel"
# What a note's helper does in the person's apps ends with every change of its run's state (the real RunToken,
# Acting.Cancel(run:) and the gate every change goes through): Pause with a press still waiting, and it never happens.
swiftc -parse-as-library -O -o "$out/runactions" Sources/Petal/ActingCancel.swift Sources/Petal/RunActions.swift Sources/Petal/Background.swift Sources/Petal/UIMap.swift Sources/Petal/NoteFile.swift Sources/Petal/NoteLibrary.swift Sources/Petal/NoteLayout.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift checks/RunActionsCheck.swift
"$out/runactions"
# The Petal Notes window opens a dialog only through NotesModel.dialog, which captures the notes folder's session and
# the notebook's binding first and checks both before applying the answer: every alert, sheet or panel in it is made
# inside one of the private functions only `dialog` calls (askWords, confirmTrash).
perl -ne '
    $func = $1 if /\bfunc (\w+)/;
    if (/runModal|NSAlert\(|\.sheet\(|NSOpenPanel|NSSavePanel|beginSheet|\.alert\(|confirmationDialog|\.fileImporter\(/ && $func !~ /^(askWords|confirmTrash)$/) {
        print "$ARGV:$.: a dialog outside NotesModel.dialog (in $func)\n"; $bad++
    }
    $private++ if /private static func (askWords|confirmTrash)\(/;
    END { if ($bad || $private != 2) { print "notes window dialogs: not all through dialog\n"; exit 1 } print "notes window dialogs: all through dialog\n" }
' Sources/Petal/NotesWindow.swift
# Every card Petal AI's tools put up says whose it is (Assist.ask's `owner`), so a chat's Stop or an agent hanging up
# answers it Don't: the parameter has no default, and every call to it (a string first: the card's kind) names it.
perl -0777 -ne '
    if ($ARGV =~ /\/Assist\.swift$/ && !/func ask\(_ kind: String[^{]*?\bowner: String\?,/s) { print "Assist.ask: owner must be said\n"; $bad++ }
    while (/\bask\("/g) {
        my $start = pos($_) - 1;
        # The call: up to its closing parenthesis, past strings and their \(...) interpolations.
        my ($i, @stack) = ($start + 1, ("("));
        while ($i < length($_) && @stack) {
            my $c = substr($_, $i, 1);
            if ($stack[-1] eq "\"") {
                if ($c eq "\\" && substr($_, $i + 1, 1) eq "(") { push @stack, "("; $i++ }
                elsif ($c eq "\\") { $i++ }
                elsif ($c eq "\"") { pop @stack }
            } elsif ($c eq "\"") { push @stack, "\"" }
            elsif ($c eq "(") { push @stack, "(" }
            elsif ($c eq ")") { pop @stack }
            $i++;
        }
        my $call = substr($_, $start, $i - $start);
        my $line = (substr($_, 0, $start) =~ tr/\n//) + 1;
        if ($call !~ /\bowner:/) { print "$ARGV:$line: ask(...) without owner:\n"; $bad++ }
        $calls++;
    }
    END { if ($bad) { print "$bad card(s) without an owner\n"; exit 1 } print "asks: all $calls name their owner\n" }
' Sources/Petal/*.swift
# A run's hidden display is never the person's screen: everything that picks or lists screens asks `Screens`
# (Screens.swift), which leaves run displays out. So nothing else reads AppKit's or CoreGraphics' own lists
# (DisplayCheck.swift counts AppKit's on purpose, to show the display is in one and not in the other).
n=$(grep -n 'NSScreen\.screens\|NSScreen\.main\|CGGetActiveDisplayList\|CGGetOnlineDisplayList\|CGMainDisplayID' Sources/Petal/*.swift | grep -v '^Sources/Petal/Screens\.swift:\|^Sources/Petal/DisplayCheck\.swift:' || true)
if [ -n "$n" ]; then echo "screens: read outside Screens (Screens.swift):"; echo "$n"; exit 1; fi
echo "screens: only through Screens"
# One scale (Scale.swift): a font size is a TextSize step and a corner a Radius step, by name, never a number. The
# made-up documents drawn for checks and snapshots are content, not Petal's interface.
n=$(grep -n '\.system(size: [0-9]\|cornerRadius: [0-9]' Sources/Petal/*.swift | grep -v '^Sources/Petal/\(ViewerSnapshot\|ViewerSamples\|HelpersCheck\|Scale\)\.swift:' || true)
if [ -n "$n" ]; then echo "scale: a font size or corner radius that is a number, not a step of Scale.swift:"; echo "$n"; exit 1; fi
echo "scale: every font size and corner is a named step"
# A write into a helper program's input fails quietly when that program has gone (the throwing write): the other
# one raises, which would end Petal now that a broken pipe no longer does (IPC.surviveBrokenPipes).
n=$(grep -n 'fileHandleForWriting\.write(' Sources/Petal/*.swift | grep -v 'write(contentsOf:' || true)
if [ -n "$n" ]; then echo "pipes: a write that raises when its reader has gone:"; echo "$n"; exit 1; fi
echo "pipes: a reader that has gone never ends Petal"
# Whether a display is there is asked of macOS's own list (Screens.isOnline): CGDisplayIsOnline goes on saying yes
# for the id of a display that's gone, so nothing relies on it (DisplayCheck.swift prints what it says, as information).
n=$(grep -n 'CGDisplayIsOnline' Sources/Petal/*.swift | grep -v '^Sources/Petal/DisplayCheck\.swift:\|^Sources/Petal/Screens\.swift:[0-9]*: *///' || true)
if [ -n "$n" ]; then echo "displays: CGDisplayIsOnline is relied on:"; echo "$n"; exit 1; fi
echo "displays: online by macOS's own list"
# What another program on the Mac can ask the running Petal over its socket: these functions, no others. Each one
# that does something for the person on their own say (a chat, an Allow, a key, a tool) is one of these on purpose;
# a new one is added here only after weighing what any program could do with it.
n=$(grep -o 'ipc\.on\(From\)\{0,1\}("[A-Za-z]*")' Sources/Petal/App.swift | sed 's/.*("\(.*\)")/\1/' | sort | tr '\n' ' ')
want="agentKeys ask assist bench chat chats close desktop dock mcpCall newChat options restart reveal search settings stack testBounce update version "
if [ "$n" != "$want" ]; then echo "socket: the running Petal's functions changed: $n"; echo "        expected: $want"; exit 1; fi
echo "socket: only the functions weighed"
# AGENTS.md and Petal's skill keep each list item and heading on a line of its own (a merge that loses a line break
# runs them together, and agents read these files).
n=$(grep -nE '[^ ]\.- [`*A-Za-z]|[^#]\.##+ ' ../AGENTS.md Resources/skill/SKILL.md || true)
if [ -n "$n" ]; then echo "docs: a list item or heading ran onto the line before it:"; echo "$n"; exit 1; fi
echo "docs: every list item and heading on its own line"
# Quitting answers later (notes are saved first), and AppKit waits for the answer inside `terminate`. Called from a
# block of the main dispatch queue (a signal's handler, an asyncAfter), that wait stops the queue, the answer never
# arrives and Petal never quits. So the one call to terminate is PetalApp.quit's, from the run loop, and the answer
# comes back on the run loop too.
n=$(grep -n 'NSApp\.terminate\|NSApplication\.shared\.terminate' Sources/Petal/*.swift | grep -vc 'RunLoop\.main\.perform(inModes: \[\.common\]) { MainActor\.assumeIsolated { NSApp\.terminate(nil) } }' || true)
r=$(awk '/func prepareToQuit\(/,/^    }$/' Sources/Petal/NoteDesk.swift | grep -c 'DispatchQueue\.main\.async' || true)
if [ "$n" != 0 ] || [ "$r" != 0 ]; then echo "quit: terminate is called outside PetalApp.quit, or its answer comes back on the main queue"; exit 1; fi
echo "quit: only from the run loop"
