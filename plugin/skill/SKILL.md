---
name: petal
description: Petal, the user's dock (on Omarchy or macOS) with a focus mode for every workspace or Desktop. Use when the user asks to change, explain or fix anything about their dock, its modes, apps, look or AI, or when something about Petal seems broken.
metadata:
  short-description: Change, explain and fix the Petal dock
---

# Petal

Petal is the user's dock, from Edgetr (free, open source: github.com/edgetr/petal). It runs on Omarchy (a plugin for
Omarchy's shell) and on macOS (Petal.app, which replaces macOS's Dock). Each workspace (Omarchy) or Desktop (macOS)
has its own focus mode, and the dock shows that mode's apps. This skill is installed by Petal itself.

## Changing the dock

Any AI session can change the dock: Petal's own panel, T3 Code, or Claude Code and Codex in a terminal. Petal
registers its MCP server (`petal`) with Claude Code and Codex and puts `petal` on the PATH (setting `otherAgents`).
Use, in this order:

1. Petal's MCP tools, when the `petal` server is connected: `petal_get_state` first, then `petal_set_settings`,
   `petal_set_dock`, `petal_save_mode`, `petal_delete_mode`, `petal_set_default_mode`, `petal_switch_mode`,
   `petal_list_apps`, `petal_reload`, `petal_reset_settings` (every setting back to its default: ask first).
   On macOS also Petal AI's tools, done by the running Petal with its own permissions: `petal_look` (what's in front:
   app, window, browser tab address, selected text; a screenshot when asked), `petal_apps`, `petal_windows`,
   `petal_trash` (the Trash, never deleting; quitting, closing and trashing ask the user first), and memory:
   `petal_remember`, `petal_forget`, `petal_memories` (everywhere or per mode); and routines, what Petal does by
   itself from the user's own words ("keep my Downloads tidy", "when I open Figma, switch to Design"):
   `petal_routine_save` (their words, plus the trigger and actions you fill in), `petal_routines`,
   `petal_routine_run` (`dryRun: true` shows what it would do with the files there now), `petal_routine_undo` (puts
   moved files back), `petal_routine_delete`. Routines only move files, never delete them.
   Using the user's apps (`computerUse`): `petal_ui` lists the front window's controls with ids (e12), and
   `petal_act` presses, types, focuses or scrolls one by id, chooses a menu item by path ("File > Export…") or
   presses a key (cmd-s), through Accessibility with Petal's own pink pointer; the user's pointer never moves. The
   first use of an app in a reply asks the user; from a session outside Petal's own chat, the first in a task (pass
   the same `task` words with each act; a new task, two quiet minutes or a Stop asks again). Menus and keys go only to the window `petal_ui` looked at, and an
   act on a window that changed since (another row selected, another title) is refused: call `petal_ui` again.
   Never private apps or password fields; what only a real click could do, ask the user to do. Only the user
   turns `computerUse` on.
   The vault (`petal_vault`, macOS): logins, contact info, addresses, payment info and API keys, filled by Petal
   into fields from `petal_ui` without the AI seeing a secret (`action: fill`, the item and `fields`
   {field: id}). A login fills by itself on its own site or app, an API key on its service's site, this Mac or an
   app; elsewhere Petal asks the user. Payment info waits for one "Buy?" card per checkout (pass what you're buying
   and the price). Missing details: `action: request` (the user types them into Petal's card); a new account:
   `action: new_login`. Never ask for a password, card or key in the chat.
   In Petal's own panel each chat is a sticky note (`aiNotes`): stuck to the window it was opened on, so
   `petal_look` looks at that window even after the user moves on (`front: true` for what's in front now).
   Changes apply instantly. `petal_export_recipe` / `petal_import_recipe` share a dock as a `.petal` file (modes,
   apps by name, look; nothing personal) or add one someone shared (`look: true` also takes its look; say what it
   adds before importing); `petal_suggestions` and `petal_summary` read the
   private activity history.
2. The `petal` command: `petal get` (everything, with each setting's help), `petal set <key> <json value>`,
   `petal mode <id>`, `petal current`, `petal modes`, `petal dock petal|macos` (macOS), `petal restart`,
   `petal recipe export [<file>]`, `petal recipe import <file> [--look]`, `petal suggest`, `petal summary`,
   `petal overview` (macOS: every Desktop and its mode), `petal panel [page]` (Omarchy: the Petal menu);
   `petal help` lists them all.
3. The files in `~/.config/petal/`; Petal reloads them within a second:

- `settings.json`: settings; `petal_get_state` (or `petal get`) lists every key with its default and help.
- `modes.json`: `{"defaultMode", "workspaces": {"<n>": "<mode id>"}, "modes": [{"id", "name", "icon", "color",
  "about", "apps", "sites", "distracting", "focusDelay", "hold", "allow"}]}`. On Omarchy apps are desktop ids and icons
  Nerd Font glyphs; on macOS apps are bundle ids, icons SF Symbol names, and workspace numbers are Desktop numbers. An
  `apps` entry that's an `https://` address is a website shortcut (the site's own icon, with a globe badge).
  `distracting` marks a mode like Social or Gaming (missing: the AI decides once and writes it); `focusDelay` is
  only a distracting mode's wait to get in (30 s if 0). `allow` holds apps and sites that are fine in the mode
  without being in its dock ("Keep it here" on a card adds them).
- `dock.json` (macOS): `position` (bottom, left, right), `autoHide`, `dock` (petal or macos), `keepWindowsClear`.
  On Omarchy, position and auto-hide live in Omarchy's shell config (`omarchy-dock position|autohide`).
- `instructions.md`: the user's own notes for the AI in Petal's panel.
- `routines.json` (macOS): the routines; change them with the routine tools rather than by hand. What they did is in
  `~/Library/Application Support/Petal/routines-log.json`.

Keep the JSON valid: Petal won't overwrite a file it can't read, and won't apply it either.

More that shapes a dock:

- **Modes by time:** the `schedule` setting, `[{"mode", "days": [1-7, 1 = Monday], "from": "HH:MM", "to": "HH:MM"}]`;
  when a block starts, the workspace or Desktop in front switches to that mode.
- **A mode's reach beyond the dock:** on macOS, `shortcut` names a Shortcuts-app shortcut run when a Desktop enters
  the mode (for example one that turns on a Focus). On Omarchy, `hyprland` (`{"borderColor": "#rrggbb" | "mode",
  "gapsIn", "gapsOut", "wallpaper"}`) styles its workspaces while one is in front; it's applied at runtime, so never
  write it into Hyprland's config.
- **Shortcuts** (`shortcuts`): Control-Option-1…9 / Space / = on macOS, Super+Ctrl+Alt on Omarchy, only where free.
- **Activity, suggestions and the weekly summary** (`activityLog`, `suggestModes`, `summary`) are private and local:
  which app is in front, a line a minute, never titles; `activityLog: false` stops it.
- **Magnification** (macOS: `magnification`, `magnificationAmount`) and Petal's menu bar icon (`menuBarIcon`).
- **Each mode's own windows** (`modeWindows`, off by default): switching mode swaps the windows and tabs. On macOS
  the other modes' windows wait just off-screen on the same Desktop (`petal restore-windows` brings every one back);
  on Omarchy each mode has its own workspace.
- **Tiling** (macOS: `tiling`, `tilingGaps`, `tilingFloat`): Petal tiles the mode's windows like Hyprland;
  Control-Option-arrows focus, with Shift swap, Control-Option-T floats a window, Control-Option-R rebalances.

## When something's wrong

1. Run `petal doctor` (add `--json` for details). It checks the install, the files, the AI apps and their sign-in,
   Petal's tools, permissions (macOS) and the logs, and says what's wrong in plain words.
2. Run `petal doctor --fix` for what it can repair safely (it backs up any file it replaces, finds the AI apps
   again, restores macOS's Dock settings, re-links the plugin on Omarchy). Run `petal doctor` again to confirm.
3. If a problem remains, or it's a bug in Petal itself, offer to report it: `petal report "<one line on what
   happened>"`. It shows the report first (redacted: no username, no window titles, no file contents) and files a
   GitHub issue on edgetr/petal with the `gh` CLI when it's signed in, or opens a filled-in issue page otherwise.
   Ask the user before reporting; never paste personal data into an issue.

On macOS `petal` may not be on the PATH: the same commands are `/Applications/Petal.app/Contents/MacOS/Petal doctor`
and `… report`. Logs: `petal logs` (Omarchy's shell log; on macOS Petal's own messages in the system log, the last
30 minutes, or `petal logs <minutes>`).

## Things to know

- Petal's AI is optional and uses the user's own Claude Code or Codex (`aiProviders`, `chatProvider`). Its usage
  counts toward the user's own plan, or on macOS toward an API key (`claudeAuth` / `codexAuth`: `subscription` or
  `api`). The key is pasted in Settings › AI and kept in the Keychain; only Petal's own runs use it. Never ask for a
  key, put one in a file or the environment, or change `~/.claude`, `~/.codex` or their logins to switch.
- On macOS, Petal hides macOS's Dock while it runs and gives it back on quit; `petal restore-dock` gives it back by
  hand. Permissions it may need: Accessibility (window lists, badges, focus cards, per-mode windows, tiling), Screen
  Recording (previews), Automation for each browser (reading and closing a tab), and Full Disk Access (reading
  notifications, to hold them).
- Focus cards (`focusGuard`): what's in front that belongs to a distracting mode is blocked ("x.com · belongs to
  Social": Stay closes the tab or hides the app; Go to Social starts its wait); something from another mode gets
  "fits Design · Move to Design?" with Keep it here; something new is sorted by the AI once (kept in its mode's
  `sites` or `allow`), and a peek says where it went (`peeks`). Only distracting modes wait to get in
  (`countdown`); each extra press halves the wait.
- Held notifications (`holdNotifications`, a mode's `hold`): they wait on their mode with a count; one that can't
  wait pops out of its mode's button (`urgentNotifications`). On macOS Petal reads them from Notification Center's
  database (Full Disk Access) and keeps macOS's banners away while holding; `petal doctor` says whether it can.

## Changing Petal itself

Make each dock the user's own with settings, modes and the look first; they apply instantly and survive updates.
When something truly needs code, change Petal's **personal source**: a git repository of Petal's source that every
update is combined with, so the user's changes are never lost.

1. `petal personal init` (once; safe to run again) sets it up from the installed release and prints where it is
   (`personal.source` in `petal_get_state`): `~/.local/share/petal/source` on Omarchy, `~/Library/Application
   Support/Petal/source` on macOS. On macOS it needs Apple's command line tools; if they're missing, macOS shows its
   own installer, and the user runs it again once they're in.
2. Edit the files there. Omarchy: the dock is QML in `plugin/` (no build); `petal restart` loads an edit to try it.
   macOS: the app is Swift in `macos/Sources/Petal/`.
3. `petal personal save "<what changed, in the user's words>"` after each change that works. It commits the edit as
   one of the user's changes. On macOS it builds first (an edit that doesn't build isn't saved: fix the errors it
   prints and save again), then installs the build and restarts Petal into it. On Omarchy, `petal restart` loads it;
   if the dock doesn't come back, `petal personal undo` takes the newest change out.

`petal personal status` and `list` show the changes, unsaved edits and the last update; `undo [<n>]` takes out
unsaved edits, or the n-th newest change; `reset` goes back to plain releases; `restore` brings a backup back (every
undo, reset and update keeps one). On Omarchy, only `plugin/` runs from the personal source; Petal's scripts
(`bin/`, `get.sh`) stay the release's.

When a release arrives, Petal combines it with the user's changes; where both touch the same code, the user's
chosen AI resolves it, keeping both intents, and the result has to build (macOS) or bring the dock up (Omarchy). If
that can't be done, the user keeps their Petal as it is and is told; `petal personal status` says why and
`petal personal retry` tries again. Never discard the user's changes to fix this: offer `petal report`.

Don't edit Petal's installed release files or Petal.app itself: the next update replaces them. A developer's git
checkout (`git clone https://github.com/edgetr/petal`, then its `install.sh` on Omarchy, or `macos/build.sh`) is
changed with git instead; `petal personal` says so there. If a change would help everyone, suggest proposing it
upstream as a pull request on edgetr/petal.
