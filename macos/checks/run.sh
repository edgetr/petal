#!/usr/bin/env bash
# Checks the window maths (tiling and parking), when the dock looks at the windows, and which controls Petal AI is
# told about (UIMap), where notes' tabs and AI sticky notes show and sit (NoteLayout), Petal Notes' files, places, edge tabs and
# room beside a window (NoteFile), how a note works in the background and what its
# preview says (Background), the vault's pure side (sites, 2FA codes, exports, when it fills by itself), and agents
# using the vault (AgentAccess: petal run's variables and redaction, who's asking, projects and grants; worktrees on
# throwaway folders in the temporary folder; writing through a full pipe; an unreadable answer and which signals it
# passes on), the notes for the AI keeping both sides of a change made elsewhere (Instructions), a routine's tidy stopping once its asker hangs up (RoutineStop), a request whose client hung up before its
# turn never being done (IPC, on a throwaway socket), an act's or vault call's Stop seen at once on any thread when its
# caller hangs up (Acting.Cancel), and that every card Petal AI's tools put up names its owner, without running Petal,
# moving any window or touching the Keychain:
#   macos/checks/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -O -o "$out/check" Sources/Petal/WindowLayout.swift checks/WindowLayoutCheck.swift
"$out/check"
swiftc -parse-as-library -O -o "$out/look" Sources/Petal/LookSchedule.swift checks/LookScheduleCheck.swift
"$out/look"
swiftc -parse-as-library -O -o "$out/uimap" Sources/Petal/UIMap.swift checks/UIMapCheck.swift
"$out/uimap"
swiftc -parse-as-library -O -o "$out/notes" Sources/Petal/NoteLayout.swift checks/NoteLayoutCheck.swift
"$out/notes"
# Petal Notes: the note file's round trip, iCloud's conflict copies, the ranked fallback of a note's places, the tabs
# on a window's edge, fading, and the room beside a window (no file, no window).
swiftc -parse-as-library -O -o "$out/papernotes" Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift checks/NotesCheck.swift
"$out/papernotes"
# A note's text in the editor and back: the same Markdown, line for line (AppKit, nothing shown).
swiftc -parse-as-library -O -o "$out/noterich" Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/NoteMentions.swift Sources/Petal/NoteEditor.swift Sources/Petal/EditMenu.swift checks/NoteRichCheck.swift
"$out/noterich"
# Petal Notes' files on throwaway folders in the temporary folder: saves that keep both, names from the disk, no
# writes through symbolic links, two notebooks' Todo.md, a renamed file's bookmark, the journal's launch recovery
# after a hang, and a cancelled tool write leaving nothing (never the Trash).
# Helpers in notes: what an @ line binds and asks, the helper's front matter (ink, steps, stamps, a watcher, a task, a
# chain) read back exactly, times and models in words, prices on a page, a notebook's memory, plain arithmetic,
# chained notes' loops and the person's checkouts (no window, no AI), and Open all never launching an app or a script
# (NoteTasks: real files, a link and a Finder alias in a throwaway folder in the temporary folder; nothing is opened).
swiftc -parse-as-library -O -o "$out/notehelp" Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/NoteTasks.swift checks/NoteHelpCheck.swift
"$out/notehelp"
# The Shielded boundary is the compiler's: what a helper tells an AI can't be made from a raw string. Each of these
# must fail to compile (a raw string interpolated into a prompt, put into what a helper is told, or made Shielded
# outside NoteShield), and the shielded way must compile.
shielded=(Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift)
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
    if (/\bguard\b.*\brun\b.*else \{ return \}/ && !/live\(|admits|token\.|runs\[|OrFail\(/) { print "NoteHelpers:$.: a run guard that returns without an outcome: $_"; $bad++ }
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
# A note tool rechecks access after the lookup's wait and right before answering.
perl -0777 -ne '
    unless (/guard let paper = self\.repick\(chosen\).*?guard readable\(paper\) else \{ return fail/s && /sendAbout\(\[paper\.noteID\], result\)/) { print "NoteTools: access must be rechecked after the wait and before answering\n"; exit 1 }
    print "notes: access rechecked after every wait\n";
' Sources/Petal/NoteTools.swift
# A file helper's document is revalidated on every placement change.
grep -q 'NoteHelp.documentShowing(placePath:' Sources/Petal/NoteHelpers.swift || { echo "NoteHelpers: a file helper's document must be revalidated"; exit 1; }
# Rule C: one admission gate. Every prompt a helper's agent gets goes through NoteHelpers.deliver (which asks
# admit), every turn's process starts only after the agent asks its gate, every tool answer to a helper goes through
# admitTool (before the tool, and again right before its answer), and a completion counts only for its own token.
perl -ne '
    $func = $1 if /^\s*(?:private |nonisolated |@MainActor )*(?:static )?func (\w+)/;
    if (/\.send\(/ && $func ne "deliver") { print "NoteHelpers:$.: a prompt sent outside deliver (the admission gate): $_"; $bad++ }
    $admits++ if $func eq "deliver" && /switch admit\(run\)/;
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
# Every helper output (answers, second opinions, failures, stops) goes through the held-answer journal (keep), and
# an entry is let go only when its write landed on the paper meant (.written, never .keptBoth).
perl -ne '
    if (/\b(keep|write)\(/) { $last = $1 }
    if (/\.ink(\.append\(| = )/ && !/^\s*\/\//) { $ink++; if ($last ne "keep") { print "NoteHelpers:$.: ink written outside keep (the held-answer journal): $_"; $bad++ } }
    $written++ if /done\?\(outcome == \.written\)/;
    END { exit 1 if $bad || !$ink || $written < 2; print "helpers: every output goes through the journal; only .written lets it go\n" }
' Sources/Petal/NoteHelpers.swift
# One agent per run: a run's agent is made fresh (sticky(for:)) and goes when the run ends; none is reused.
perl -0777 -ne '
    my $made = () = /StickyNote\(\)/g;
    unless ($made == 1 && /func sticky\(for paper: PaperNote\) -> StickyNote \{\s*let sticky = StickyNote\(\)/ && /let sticky = run\.sticky \?\? sticky\(for: paper\)/
            && /let reviewer = sticky\(for: paper\)/ && /func retire\(_ run: Run\) \{\s*if let sticky = run\.sticky \{ drop\(sticky\) \}/) {
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
# A second opinion is part of its primary run: it carries the note's complete ink, and every outcome of it (an answer,
# objections, a failure, a stop) is added after the primary through one path (output → opinion), never in its place.
# A reviewer outside a worktree is bound to the note's place like any run.
perl -0777 -ne '
    unless (/run\.carried = carried/ && /private func output\(_ run: Run.*?post\(run\.noteID, ink, steps: steps, helper: helper, opinionBy: run\.carried == nil \? nil : run\.who/s
            && /private func post\(.*?NoteHelp\.withOpinion\(/s && /let model = asked\?\.model \?\? run\.holes.*?self\.secondOpinion\(paper, model, asked: words, tree: run\.tree, carried: carried/s
            && /folder: tree, placed: tree == nil\)/ && /where run\.launched && run\.kind\.placed/ && /= run\.kind\.placed \? NoteHelp\.requirement\(/
            && /if run\.kind\.placed \{\s*facts\.document/) { print "NoteHelpers: a second opinion must add to its primary and be bound to its place\n"; exit 1 }
    for my $f (qw(fail stopped)) { unless (/func $f\([^\n]*end\(run, \./) { print "NoteHelpers: $f must end through end\n"; exit 1 } }
    print "helpers: second opinions add to their primary, failures included; reviewers bound to their place\n";
' Sources/Petal/NoteHelpers.swift
# Return runs a line only as the person wrote or edited it: the editor hands only a runnable line (its identity, a
# mark set by the person's own typing or pasting; undo, redo, autocorrect and text from outside clear it, never set
# it), and nothing about its words is kept. A bare @Petal and a note whose id isn't lasting are refused or waited on
# before the line is taken or any run registered; control requests come before follow-up routing; a follow-up's line
# goes with it through delivery; an empty prompt never reaches an agent.
perl -0777 -ne '
    unless (/func returned\(_ key: String, line: String, at ticket: NoteLine\) \{.*?if NoteHelp\.bare\(trimmed\) \{ return reply\(noteID, giveBack: nil\) \{ _ in NoteHelp\.bareHint.*?guard NoteShelf\.lasting\(noteID, pending: desk\.store\.pendingIDs\) else \{\s*return desk\.store\.ensureID\(.*?ticket\.take\(\).*?if NoteHelp\.isControl\(request\) \{ return control\(.*?NoteHelp\.followUpTarget\(/s
            && /func deliver\(.*?guard !prompt\.text\.trimmingCharacters/s && /func letGo\(.*?run\.line\?\.again\(\)/s
            && /followUps\.add\(told\.ask, note: noteID, token: run\.token, line: ticket\)/ && /followUp\(run, next\.text, line: next\.line\)/
            && /private func followUp\(_ run: Run, _ words: Shielded, line: NoteLine\?\) \{\s*if let line \{ run\.line = line \}/) {
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
    my $gated = () = /provider: provider, gate: self\.quickGate\(run\)\)/g;
    unless ($quick == 2 && $gated == 2 && /func quickGate\(.*?switch self\.admit\(run\)/s && /Self\.verifyTree\(stored, noteID: paper\.noteID, token: run\.token\)/
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
' Sources/Petal/Focus.swift
# Only a run that succeeded writes `done` (what chains and morning notes wait for), inside `end` once its token
# completed; every other reply is a faint word that leaves the note's ink and helper line as they are.
perl -0777 -ne '
    my $done = () = /state: \.done/g;
    unless ($done == 1 && /private func complete\(_ run: Run, made:.*?run\.token\.complete\(\.succeeded\).*?state: \.done/s
            && /private func reply\(_ noteID: String, giveBack line: NoteLine\?.*?\{\s*line\?\.again\(\)\s*guard !parts\.isEmpty else \{ return hint\(noteID, words\(\[\]\)\) \}/s) {
        print "NoteHelpers: only a succeeded run writes done; replies stay faint\n"; exit 1 }
    print "helpers: only a succeeded run writes done; replies are faint\n";
' Sources/Petal/NoteHelpers.swift
# A second opinion goes through the same checkout choice as a primary request, and one asked while a run works rides
# with its line (the same queue as follow-ups: given back if that run doesn't succeed, held by the reviewer until it does).
perl -0777 -ne '
    unless (/private func review\(.*?NoteHelp\.reviewCheckout\(current: current, words: asked.*?followUps\.addReview\(model, asked: asked, note: paper\.noteID, token: run\.token, line: taking\)/s
            && /let settled = followUps\.settle\(note: noteID, token: run\.token, succeeded: true\).*?let asked = settled\.review.*?let line = asked\?\.line.*?self\.taking = line/s) {
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
    unless ($direct == 3 && $nil == 1 && /private func complete\(_ run: Run, made:.*?let next = handOn\(run\)/s && /let settled = followUps\.settle\(note: noteID, token: run\.token, succeeded: true\)\s*for line in settled\.dropped \{ line\.again\(\) \}/
            && /private func release\(_ run: Run\) \{\s*if runs\[run\.noteID\] === run \{\s*runs\[run\.noteID\] = nil/
            && !/func say\(|func refuse\(|func succeeded\(|func answer\(|desk\.tell\(/ && $hints == 2
            && /self\.end\(run, \.succeeded\(nil\)\)/ && /self\.end\(run, \.succeeded\(Said\(who: who, text: line, form: \.words\)\)\)/
            && /self\.end\(run, \.succeeded\(said\)\)|end\(run, \.succeeded\(said\)\)/
            && /run\.kind == \.quick \{\s*return reply\(paper\.noteID, giveBack: taking\) \{ _ in "A quick helper/) {
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
' Sources/Petal/Focus.swift
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
            && /private func hint\(_ noteID: String, _ words: Shielded\)/ && !/\.label\(\)/ && !/label\.prefix|prefix\(48\)|prefix\(30\)/) {
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
    unless (/private func post\(_ noteID: String, _ ink: \[NoteHelp\.Ink\]\?, steps: \[Shielded\]\?/
            && /case \.succeeded\(let said\):.*?Self\.shieldSaid\(said\) \{ made in.*?guard let made else \{ return self\.end\(run, \.failed\(Self\.vaultWords\.text\)\) \}.*?self\.complete\(run, made: made\)/s
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
# The agent's boundary: every provider event shielded in order on its own queue before anything reads it; activity
# is Shielded for every agent (a chat's and an AI note's previews too); a helper's event the vault can't shield fails it.
perl -0777 -ne '
    unless (/var activity: Shielded = ""/ && /ingest\.async \{\s*let shown = Agent\.shield\(lines\.flatMap \{ provider\.events\(\$0\) \}, helper: helper\)/
            && /guard let shown else \{ return self\.vaultLost\(\) \}\s*for \(event, words\) in shown \{ self\.apply\(event, words: words\) \}/
            && /ingest\.async \{ DispatchQueue\.main\.async \{/ && /activity = words \?\? ""/ && !/for event in provider\.events\(line\) \{ self\.apply\(event\) \}/) {
        print "Agent: every event is shielded at the boundary before anything reads it\n"; exit 1 }
    print "agent: every event shielded at the boundary; activity is Shielded\n";
' Sources/Petal/Claude.swift
grep -q 'NoteHelpers.shield(\[job.caption\])' Sources/Petal/ComputerUse.swift || { echo "ComputerUse: its caption goes on as activity only once shielded"; exit 1; }
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
    unless (/private func told\(.*?case \.notHere, \.conflict:\s*guard waited < Self\.coverWait else \{\s*reply\(.*?Couldn.t read .*?cover yet.*?return end\(run, \.stopped\(nil\)\)/s
            && /raw\.coverOf = / && !/raw\.cover = mayRead/) { print "NoteHelpers: a cover that can.t be read is waited for, then refused\n"; exit 1 }
    print "helpers: an unreadable cover is waited for, then refused, never skipped\n";
' Sources/Petal/NoteHelpers.swift
# Every reviewer output, its turns on the way included, goes through opinion (output).
perl -0777 -ne '
    if (/Something said meanwhile.*?\n\s*return\n/s && $& !~ /turnOutput\(run, Said\(who: run\.who, text: answer, steps: steps, form: run\.carried == nil \? \.answer : \.opinion\)\)/) { print "NoteHelpers: a reviewer turn must go through output\n"; exit 1 }
    print "helpers: every reviewer output goes through opinion\n";
' Sources/Petal/NoteHelpers.swift
# Helpers read and write a cover only by the cover rule (the file named for it in the notebook's own folder).
if grep -n 'file\.cover\b' Sources/Petal/NoteHelpers.swift; then echo "NoteHelpers: helpers find covers by name, never by cover: true"; exit 1; fi
[ "$(grep -c 'coverToChange(paper' Sources/Petal/NoteHelpers.swift)" -ge 4 ] || { echo "NoteHelpers: every cover change goes through coverToChange"; exit 1; }
echo "helpers: covers by the cover rule; a cover in conflict gets no memory"
swiftc -parse-as-library -O -o "$out/notestore" Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/PaperNotes.swift Sources/Petal/NoteJournal.swift checks/NoteStoreCheck.swift
"$out/notestore"
# A passage for Petal AI follows petal_look's rule for selected text (UIMap.selectionHidden), and what the note tools
# tell an agent is redacted with the vault's index, or not told while the vault can't be read (NoteShield).
swiftc -parse-as-library -O -o "$out/noteselection" Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteHelp.swift Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift checks/NoteSelectionCheck.swift
"$out/noteselection"
swiftc -parse-as-library -O -o "$out/background" Sources/Petal/Background.swift Sources/Petal/UIMap.swift checks/BackgroundCheck.swift
"$out/background"
swiftc -parse-as-library -O -o "$out/vault" Sources/Petal/Vault.swift Sources/Petal/UIMap.swift checks/VaultCheck.swift
"$out/vault"
swiftc -parse-as-library -O -o "$out/agents" Sources/Petal/AgentAccess.swift Sources/Petal/AgentCallers.swift checks/AgentAccessCheck.swift
"$out/agents"
# The notes for the AI in the settings window: typing, changes made elsewhere, picks and late answers (no file).
swiftc -parse-as-library -O -o "$out/instructions" Sources/Petal/InstructionsState.swift checks/InstructionsCheck.swift
"$out/instructions"
swiftc -parse-as-library -O -o "$out/routinestop" Sources/Petal/RoutineStop.swift checks/RoutineStopCheck.swift
"$out/routinestop"
# Which Petal processes are a dock: a benchmark, snapshot, the AI's tools or a command never count as a second one
# (PetalProcess; the Dock guard's shell test with pgrep and ps stood in for, never a real Petal).
swiftc -parse-as-library -O -o "$out/petalprocess" Sources/Petal/PetalProcess.swift checks/PetalProcessCheck.swift
"$out/petalprocess"
# IPC.swift on a throwaway socket in the temporary folder (never Petal's): a request whose client hangs up first is
# never done.
swiftc -parse-as-library -O -o "$out/ipc" Sources/Petal/IPC.swift Sources/Petal/AgentAccess.swift Sources/Petal/AgentCallers.swift checks/IPCCheck.swift
"$out/ipc"
# An act's or vault call's Acting.Cancel for a caller outside Petal stops the moment its request is hung up, on any
# thread, with the main thread blocked (IPC.Pending, no socket).
swiftc -parse-as-library -O -o "$out/cancel" Sources/Petal/ActingCancel.swift Sources/Petal/IPC.swift Sources/Petal/AgentAccess.swift Sources/Petal/AgentCallers.swift checks/CancelCheck.swift
"$out/cancel"
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
