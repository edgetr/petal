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
# An automatic approval (an earlier Always, Full access) is registered on the asking helper run's token first.
perl -0777 -ne '
    unless (/let grant = NoteHelp\.autoGrant\(.*?\) \{\s*return done\(app\.paper\.helpers\.authorized\(owner, grant\)\)/s) { print "Assist.ask: an automatic approval must register on the run first\n"; exit 1 }
    print "helpers: automatic approvals register on the run\n";
' Sources/Petal/Assist.swift
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
