# Petal

**An AI-native dock for [Omarchy](https://omarchy.org).**
Focus modes per workspace, a dock that knows what you're doing, and Claude Code built in.
Want it different? Just ask Claude.

**[Download →](https://petal-dock.vercel.app)** · [Releases](https://github.com/edgetr/petal/releases)

## What it does

- **Focus modes.** Building, Writing, Social, or any modes you make. Each mode has its own apps,
  color and rules. Every workspace remembers its mode, so swiping between workspaces swaps the
  dock too. Click a mode to switch.
- **Focus cards.** When the window in front doesn't belong to the mode you're in, a small card
  asks: *stay focused, or switch?* Petal knows your apps; for anything new (a website, an app
  it hasn't seen) Claude Haiku decides which mode it belongs to.
- **Held notifications.** In a mode that holds notifications, messages from apps outside the
  mode are taken off screen (they stay in Omarchy's notification history) and wait on their
  mode with a count. Your mode's own apps come through normally, buttons and all. Claude flags
  held messages that can't wait.
- **Claude, in the dock.** The Claude button opens a real Claude Code chat. Ask it to add a mode,
  restyle the dock, fix a config, find a file or explain why your laptop is slow. It reads, edits
  and runs safe commands on its own (Claude Code's auto mode); anything risky comes back as
  **Allow / Don't allow**. Or switch on full access.
- **Customize anything by asking.** Petal ships an MCP server that Claude gets automatically, so
  "make the dock background black", "bigger icons", "stop the bouncing" or "move the dock to the
  left" just work. If a setting can't do it, Claude can edit Petal's own code.
- **Usage ring.** A ring around the Claude button shows how much of your Claude Code limit is
  used (pink, amber at 70%, red at 90%). Hover for numbers; the panel shows when it resets.
- **A good dock, too:** unread badges, a single bounce when an app needs you, download progress
  rings, quick actions and recent files on right-click, drop files on an app to open them (or on
  the trash), live window previews, minimized windows (Super+M) as thumbnails, now playing,
  folder stacks, app-colored glow, hover lift, auto-hide, every screen.

Right-click the dock for the few settings you'll touch often (position, auto-hide, focus cards,
holding notifications). Everything else: ask Claude.

## Requirements

- **Omarchy 4.5+**. Petal is a plugin for Omarchy's shell (Quickshell on Hyprland), so it runs on Omarchy only, not on other Linux setups.
- `busctl` (systemd), `gio`, `python3`: all on a stock Omarchy install
- **Optional, for the AI features:** [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  (`claude` CLI), logged in. Petal uses your existing Claude Code login and plan, and its
  calls count toward your Claude usage. Without it, everything else works.
- A Nerd Font for the mode icons (Omarchy ships JetBrainsMono Nerd Font)

## Install

**One line** (or use the download button on [the website](https://petal-dock.vercel.app)):

```bash
curl -fsSL https://petal-dock.vercel.app/install.sh | bash
```

This downloads the latest [release](https://github.com/edgetr/petal/releases), checks its
checksum, installs it to `~/.local/share/petal`, and restarts Omarchy's shell. Turn off
Omarchy's own dock if it is on, so you don't have two.

**Updates are automatic:** Petal checks GitHub Releases a couple of minutes after starting and
every 6 hours, installs a newer version, and offers to restart the shell. Or run `petal update`.
(Ask Claude to turn auto-update off if you'd rather not.)

### Manual download

Download `Petal-linux.tar.gz` from [Releases](https://github.com/edgetr/petal/releases/latest),
then:

```bash
tar -xzf Petal-linux.tar.gz && cd petal && ./install.sh && omarchy restart shell
```

### Build from source

```bash
git clone https://github.com/edgetr/petal ~/Dev/Petal
cd ~/Dev/Petal
./install.sh
omarchy restart shell
```

A source install isn't auto-updated; use `git pull && petal restart`.

`install.sh`:

1. links `plugin/` into `~/.config/omarchy/plugins/egesuren.petal`
2. links the `petal` command into `~/.local/bin`
3. creates `~/.config/petal/modes.json` from `defaults/modes.json` (if you don't have one)
4. finds your `claude` CLI and writes its path to `~/.config/petal/settings.json`
5. enables the plugin in `~/.config/omarchy/shell.json`

### Releasing (maintainers)

Bump `version` in `plugin/manifest.json`, commit, then tag and push:

```bash
git tag v3.2.0 && git push origin v3.2.0
```

The release workflow builds `Petal-<version>-linux.tar.gz`, `Petal-linux.tar.gz` and
`latest.json` (version, URL, SHA-256), which every installed Petal checks for updates.
macOS and Windows builds will join the same `latest.json` later.

## First steps

1. **Pick a mode** for each workspace: click Building, Writing or Social. Each workspace remembers it.
2. **Add apps** to a mode with the **+** button (type to search; folders become stacks).
   Right-click an app and use **In modes** to put it in several modes.
3. **Right-click a mode** to make it hold notifications, set it as default, or delete it.
   Turn on *Countdown to leave* in settings if you want a delay before leaving focus modes.
4. **Click the Claude button** and try *"Add a Gaming mode with Steam and Discord"* or
   *"Make the dock background black"*.

## Customizing

The easy way is to ask Claude. Under the hood, everything lives in `~/.config/petal/` and
reloads live when saved:

- **`settings.json`**: appearance (`dockColor`, `dockOpacity`, `dockRadius`, `iconSize`,
  `accentColor`, `font`, `popupColor`, …) and feature switches (`bounce`, `badges`, `previews`,
  `appGlow`, `autoUpdate`, …), plus the Claude panel's `chatModel`, `chatEffort` and
  `claudeAccess` (`auto` or `full`). The full list with descriptions is in
  [`plugin/mcp/petal-mcp.py`](plugin/mcp/petal-mcp.py).
- **`modes.json`**: your modes:

```jsonc
{
  "defaultMode": "building",            // for workspaces you haven't set
  "workspaces": { "1": "building" },    // workspace number -> mode (Petal fills this in)
  "modes": [
    {
      "id": "building",
      "name": "Building",
      "icon": "󰣪",                       // one Nerd Font glyph or emoji
      "color": "#b18cff",
      "about": "coding, terminals, GitHub", // what it's for; Claude sorts activity with this
      "apps": ["com.mitchellh.ghostty", "code"], // desktop ids, in dock order
      "sites": ["github", "localhost"],  // words in browser tab titles that belong here
      "focusDelay": 15,                 // countdown (s) before leaving, if countdowns are on
      "hold": true,                     // hold notifications from apps outside this mode
      "allow": ["slack"]                // apps whose notifications always come through
    }
  ]
}
```

- **`instructions.md`** (optional): your own standing instructions for Claude, added to every
  chat ("Always answer in Turkish", "I use Helium, not Chrome", …).

### The Petal MCP server

`plugin/mcp/petal-mcp.py` is a dependency-free MCP server with tools to read Petal's state, change
settings and modes, move the dock and reload it. The Claude panel connects it automatically. To
use it from any Claude Code session too:

```bash
claude mcp add petal -- python3 ~/.local/share/petal/current/plugin/mcp/petal-mcp.py
```

## The `petal` command

```
petal mode <id>   switch this workspace to a mode
petal current     print this workspace's mode
petal modes       list modes and their apps
petal ask         open the Claude panel
petal search      open the add-apps search
petal settings    open the settings menu
petal edit        edit modes.json
petal restart     restart Omarchy's shell (reloads Petal)
petal update      update from GitHub Releases (--check to only look)
petal version     the installed version
```

## Privacy

Petal itself sends nothing anywhere. With **Sort with Claude** on, the app name and window
title of windows it doesn't recognize, and the app, title and text of notifications it holds,
are sent to Claude through your Claude Code CLI. The Claude panel works like any Claude Code
session in your home folder. Turn **Sort with Claude** off to keep window titles and
notifications local.

## Troubleshooting

- **Dock doesn't show:** `omarchy restart shell`, then check the log:
  `quickshell log "$(ls -td /run/user/$UID/quickshell/by-id/*/ | head -1)log.qslog" | grep -i petal`
- **Claude features do nothing:** check `claudePath` in `settings.json` and that `claude -p hi` works in a terminal.
- **Usage ring missing:** it uses Omarchy's `omarchy-agent-usage-claude`; run it to see if it works.
- **Two docks:** turn off Omarchy's built-in dock.

## Uninstall

```bash
./uninstall.sh && omarchy restart shell
```

## Credits

Made by [Edgetr](https://edgetr.tech) in Istanbul, with Claude. Inspired by an AI-native
focus dock idea from Thariq. The Claude logo is a trademark of Anthropic; Petal is not
affiliated with Anthropic or Omarchy.

MIT licensed.
