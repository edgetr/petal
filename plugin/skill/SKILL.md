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

1. Petal's MCP tools, when the `petal` server is connected:
`petal_get_state` first, then `petal_set_settings`, `petal_set_dock`, `petal_save_mode`, `petal_delete_mode`,
`petal_set_default_mode`, `petal_switch_mode`, `petal_list_apps`, `petal_reload`. Changes apply instantly.
2. The `petal` command: `petal get` (everything, with each setting's help), `petal set <key> <json value>`,
   `petal mode <id>`, `petal current`, `petal modes`, `petal dock petal|macos` (macOS), `petal restart`; `petal help`
   lists them all.
3. The files in `~/.config/petal/`; Petal reloads them within a second:

- `settings.json`: settings; `petal_get_state` (or `petal doctor --json`) lists every key with its default and help.
- `modes.json`: `{"defaultMode", "workspaces": {"<n>": "<mode id>"}, "modes": [{"id", "name", "icon", "color",
  "about", "apps", "sites", "focusDelay", "hold", "allow"}]}`. On Omarchy apps are desktop ids and icons Nerd Font
  glyphs; on macOS apps are bundle ids, icons SF Symbol names, and workspace numbers are Desktop numbers.
- `dock.json` (macOS): `position` (bottom, left, right), `autoHide`, `dock` (petal or macos), `keepWindowsClear`.
  On Omarchy, position and auto-hide live in Omarchy's shell config (`omarchy-dock position|autohide`).
- `instructions.md`: the user's own notes for the AI in Petal's panel.

Keep the JSON valid: Petal won't overwrite a file it can't read, and won't apply it either.

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
and `… report`. Logs: `petal logs` (Omarchy's shell log; on macOS the system log for Petal).

## Things to know

- Petal's AI is optional and uses the user's own Claude Code or Codex (`aiProviders`, `chatProvider`). Its usage
  counts toward the user's own plan.
- On macOS, Petal hides macOS's Dock while it runs and gives it back on quit; `petal restore-dock` gives it back by
  hand. Permissions it may need: Accessibility (window lists, badges, focus cards) and Screen Recording (previews).
- Focus cards ("x.com belongs to Social") appear only in modes with `focusDelay` above 0, with `focusGuard` on.
## Changing Petal itself

Make each dock the user's own with settings, modes and the look first; they apply instantly and survive updates.
When something truly needs code:

- **Omarchy:** Petal is QML, in the folder `petal_get_state` gives as `plugin_source`. Edit it, then `petal restart`
  (or `petal_reload`). A Petal update replaces a release install's files, so keep the change small and tell the user;
  a source checkout (`git clone https://github.com/edgetr/petal`, then its `install.sh`) keeps it.
- **macOS:** Petal is a Swift app. With a source checkout (`plugin_source` when there is one, else clone it), edit
  `macos/Sources/Petal/`, build with `macos/build.sh` (needs Apple's developer tools), copy `macos/build/Petal.app`
  over the running app (`files.app` in `petal_get_state`), and `petal restart`.
- If the change would help everyone, suggest proposing it upstream as a pull request on edgetr/petal.
