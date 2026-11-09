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
swiftc -parse-as-library -O -o "$out/noterich" Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift Sources/Petal/NoteHelp.swift Sources/Petal/NoteMentions.swift Sources/Petal/NoteEditor.swift Sources/Petal/EditMenu.swift checks/NoteRichCheck.swift
"$out/noterich"
# Petal Notes' files on throwaway folders in the temporary folder: saves that keep both, names from the disk, no
# writes through symbolic links, two notebooks' Todo.md, a renamed file's bookmark, the journal's launch recovery
# after a hang, and a cancelled tool write leaving nothing (never the Trash).
# Helpers in notes: what an @ line binds and asks, the helper's front matter (ink, steps, stamps, a watcher, a task, a
# chain) read back exactly, times and models in words, prices on a page, a notebook's memory, plain arithmetic,
# chained notes' loops and the person's checkouts (no file, no window, no AI).
swiftc -parse-as-library -O -o "$out/notehelp" Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift Sources/Petal/NoteHelp.swift checks/NoteHelpCheck.swift
"$out/notehelp"
swiftc -parse-as-library -O -o "$out/notestore" Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift Sources/Petal/PaperNotes.swift Sources/Petal/NoteJournal.swift checks/NoteStoreCheck.swift
"$out/notestore"
# A passage for Petal AI follows petal_look's rule for selected text (UIMap.selectionHidden), and what the note tools
# tell an agent is redacted with the vault's index, or not told while the vault can't be read (NoteShield).
swiftc -parse-as-library -O -o "$out/noteselection" Sources/Petal/UIMap.swift Sources/Petal/NoteShield.swift Sources/Petal/NoteFile.swift Sources/Petal/NoteLayout.swift checks/NoteSelectionCheck.swift
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
