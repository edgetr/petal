# Petal: notes for agents

Omarchy shell plugin (Quickshell/QML, Hyprland 0.56 Lua config). Reload with
`omarchy restart shell` (plugin hot reload is unreliable). Logs:
`quickshell log "$(ls -td /run/user/$UID/quickshell/by-id/*/ | head -1)log.qslog"`.

## Changing modes (the user may ask you to)
Edit `~/.config/petal/modes.json`; Petal reloads it live.
```
{ "defaultMode": "<id>", "workspaces": { "<n>": "<id>" },
  "modes": [ { "id", "name", "icon": "<Nerd Font glyph>", "color": "#rrggbb",
    "about": "what it's for (Claude sorts activity with this)",
    "apps": ["<desktop id>", ...],          // dock order
    "sites": ["<word in tab titles>", ...],
    "focusDelay": <seconds, 0 = no guard>,
    "hold": <bool>, "allow": ["<desktop id>"] } ] }
```
Desktop ids: file names in /usr/share/applications or ~/.local/share/applications, minus `.desktop`.

## Code map
- `Dock.qml`: root service: settings, modes, items per workspace, focus guard, notification holding, IPC (`omarchy-shell petal …`).
- `DockWindow.qml`: one dock per screen (UI, menus, cards).
- `Brain.qml`: quick JSON calls (`claude -p --model haiku --effort low`) to sort windows/notifications into modes. Chat model/effort/access: settings chatModel/chatEffort/claudeAccess.
- Usage: `omarchy-agent-usage-claude --limits-only` every 5 min; `percent` is a 0–1 fraction.
- Holding: no Do Not Disturb; held notifications are removed from Omarchy's screen with `omarchy-shell notifications dismiss <summary>`, allowed ones show natively.
- `Signals.qml`: `busctl monitor` for notifications and LauncherEntry progress/badges.
- `AppSearch.qml` ("+" search, apps and folders), `AskBox.qml` (Claude panel UI), `Agent.qml` (Claude Code chat: stream-json, resume, Allow re-runs with per-part `Bash(...)` rules).

- `Agent.qml` passes `--mcp-config` for `plugin/mcp/petal-mcp.py` (stdlib-only MCP server) and allows `mcp__petal`; `~/.config/petal/instructions.md` is appended to the system prompt.
- Settings: the JsonAdapter in `Dock.qml` and `SETTINGS_SCHEMA` in `petal-mcp.py` must list the same keys. New feature or look → add both, so Claude can change it.
- Releases: bump `plugin/manifest.json` version, tag `vX.Y.Z`, push the tag; `.github/workflows/release.yml` builds the tarball + `latest.json`. `get.sh` installs/updates from it (`petal update`); source checkouts report `dev` and aren't touched.
- Website: `site/` (static, Vercel project `petal-dock`, root dir `site`); `/install.sh` redirects to `get.sh` on main.

## Gotchas
- User plugins get no shellConfig/appLibrary; read shell.json via FileView, launch with `uwsm-app -- <id>.desktop`.
- Don't name QML properties `left`/`right`/etc. (FINAL on Item).
- ColorQuantizer can't read `image://icon`; icon color is sampled with a Canvas.
- Inline-component handlers in a derived use override the base; use Connections.
- The right-click settings menu stays tiny (position, auto-hide, focus cards, hold notifications); everything else is changed by asking Claude (MCP).
- No secrets in the repo; the release workflow only uses the built-in GITHUB_TOKEN.
- Popups: Glass (hairline border), Adwaita Sans, switches for on/off rows; keep them calm.
