# Petal

**A dock with your AI built in.** For the Mac and for [Omarchy](https://omarchy.org).
Your own Claude Code or Codex lives in the dock, so you change anything about it by asking.
On the Mac it also has sticky notes that can do things; on Omarchy, a focus mode for every workspace.

**[Download](https://petal.codes)** · [Releases](https://github.com/edgetr/petal/releases)

## On both

- **AI in the dock.** The AI button opens a chat with your own Claude Code or Codex, on your own plan.
  Ask it to restyle the dock, move it, reorder your apps, fix a config or find a file. Anything risky
  comes back as **Allow / Don't allow**, or switch on full access.
- **Customize anything by asking.** Petal gives the AI its own tools, so "make the dock darker",
  "bigger icons", "stop the bouncing" or "move the dock to the left" just work. If a setting can't do
  it, the AI can edit Petal's own code, and Petal keeps your change through every update.
- **Usage ring.** A ring around the AI button shows how much of your plan's limit is used. Hover for
  numbers.
- **A good dock, too:** unread badges, a single bounce when an app needs you, download progress
  rings, drop files on an app to open them (or on the Trash), live window previews, minimized windows
  as thumbnails, now playing, folder stacks, website shortcuts, auto-hide, every screen.
- **Optional AI.** Without Claude Code or Codex, everything else works.

## Petal for macOS

A native app for macOS 26 and later that takes the place of your Dock, on Liquid Glass. It gives
your own Dock back whenever you quit.

- **One dock.** Your apps and website shortcuts in the order you want, the same on every Desktop.
  The first launch offers to bring over what's in your Dock.
- **Petal Notes.** Your own writing on paper, stuck to places: a sentence, a browser tab, a window,
  an app, a file, a person you're chatting with, or the screen itself. Drag a paper off the note pad
  in the dock and let it go anywhere, or press ⌃⌥N. Each note is a Markdown file and each notebook a
  folder, in your iCloud Drive. The Petal Notes window (the mark in the menu bar) holds them all.
- **Helpers in notes.** Write `@Petal` and what you want on a line, then press Return. It works in
  the background and the answer comes back as ink on the note. A note takes its instructions in
  plain words: "bring this back Friday", "check this every morning".
- **Petal's viewer.** Open a PDF, a Word document or a deck with your notes in the margin beside the
  passage they're about.
- **Petal AI.** It sees what's in front of you and can use your apps for you with a pointer of its
  own (yours never moves). What changes something asks first: Allow, Always or Don't. Stop or Escape
  ends it.
- **The vault.** Logins, addresses, cards and API keys in your Keychain. Petal AI logs in, fills
  forms and checks out with them without ever seeing a password, a card number or a key. Your own
  agents in a terminal can use it too, once you allow them for a project (`petal run`).
- **Routines.** "Keep my Downloads tidy." Describe it once and Petal does it by itself. Files are
  moved, never deleted.
- **Tiling**, off by default: Petal tiles the windows on each Desktop.

### Install

Download **Petal for Mac** from [the website](https://petal.codes) and open it. Petal has
no Apple Developer ID, so the first time macOS won't open it: go to System Settings › Privacy &
Security and choose **Open Anyway**.

Or, in a terminal, which skips that step:

```bash
curl -fsSL https://petal.codes/install.sh | bash
```

Petal asks for Accessibility (to see your windows, and to use apps when you ask it to) and Screen
Recording (for window previews). It updates itself from
[GitHub Releases](https://github.com/edgetr/petal/releases): the mark in the menu bar turns blue
when a new version is ready, and it restarts when you say so.

To build it yourself: `macos/build.sh`, which makes `macos/build/Petal.app` (Swift Package Manager,
no dependencies).

## Petal for Omarchy

A plugin for Omarchy's shell, with a focus mode for every workspace.

- **Focus modes.** Building, Writing, Social, or any modes you make. Each mode has its own apps,
  color and rules. Every workspace remembers its mode, so swiping between workspaces swaps the
  dock too. Click a mode to switch.
- **Focus cards.** When the window in front belongs to a distracting mode, a small card asks:
  *stay, or go there?* Petal knows your apps; anything new (a website, an app it hasn't seen) is
  sorted once by the AI.
- **Held notifications.** In a mode that holds notifications, messages from apps outside the
  mode are taken off screen (they stay in Omarchy's notification history) and wait on their
  mode with a count. Your mode's own apps come through normally. One that can't wait finds you.

Right-click the dock for the few settings you'll touch often (position, auto-hide, focus cards,
holding notifications). Everything else: ask the AI.

The rest of this page is about Petal for Omarchy.

## Requirements

- **Omarchy 4.5+**. Petal is a plugin for Omarchy's shell (Quickshell on Hyprland), so it runs on Omarchy only, not on other Linux setups.
- `busctl` (systemd), `gio`, `python3`: all on a stock Omarchy install
- **Optional, for the AI features:** [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  (`claude`) or Codex (`codex`), logged in. Petal uses your existing login and plan, and its
  calls count toward that plan's usage. Without one, everything else works.
- A Nerd Font for the mode icons (Omarchy ships JetBrainsMono Nerd Font)

## Install

**One line** (or use the download button on [the website](https://petal.codes)):

```bash
curl -fsSL https://petal.codes/install.sh | bash
```

This downloads the latest [release](https://github.com/edgetr/petal/releases), checks its
checksum, installs it to `~/.local/share/petal`, and restarts Omarchy's shell. Turn off
Omarchy's own dock if it is on, so you don't have two.

**Updates are automatic:** Petal checks GitHub Releases a couple of minutes after starting and
every 6 hours, installs a newer version, and offers to restart the shell. Or run `petal update`.
(Ask the AI to turn auto-update off if you'd rather not.)

### Manual download

Download `Petal-linux.tar.gz` from [Releases](https://github.com/edgetr/petal/releases/latest),
then:

```bash
tar -xzf Petal-linux.tar.gz && cd petal && ./install.sh && omarchy restart shell
```

### Build from source

```bash
git clone https://github.com/edgetr/petal ~/Projects/Petal
cd ~/Projects/Petal
./install.sh
omarchy restart shell
```

A source install isn't auto-updated; use `git pull && petal restart`.

`install.sh`:

1. links `plugin/` into `~/.config/omarchy/plugins/egesuren.petal`
2. links the `petal` command into `~/.local/bin`
3. creates `~/.config/petal/modes.json` from `defaults/modes.json` (if you don't have one)
4. finds your `claude` and `codex` CLIs and notes them in `~/.config/petal/settings.json`
5. enables the plugin in `~/.config/omarchy/shell.json`

### Releasing (maintainers)

Each platform ships on its own. For Omarchy, bump `version` in `plugin/manifest.json`, commit, then
tag and push:

```bash
git tag v3.2.0 && git push origin v3.2.0
```

The release workflow builds `Petal-<version>-linux.tar.gz`, `Petal-linux.tar.gz` and
`latest.json` (version, URL, SHA-256), which every installed Petal checks for updates.

For macOS, bump `macos/VERSION`, point `/download/mac` in `site/vercel.json` at the new version,
write `macos/notes/<version>.md` (it becomes What's New), commit, then tag `macos-v<version>` and
push. That workflow builds `Petal-<version>-macos.zip` and `latest-macos.json`.

## First steps

1. **Pick a mode** for each workspace: click Building, Writing or Social. Each workspace remembers it.
2. **Add apps** to a mode with the **+** button (type to search; folders become stacks).
   Right-click an app and use **In modes** to put it in several modes.
3. **Right-click a mode** to make it hold notifications, set it as default, or delete it.
   Turn on *Countdown to leave* in settings if you want a delay before leaving focus modes.
4. **Click the AI button** and try *"Add a Gaming mode with Steam and Discord"* or
   *"Make the dock background black"*.

## Customizing

The easy way is to ask the AI. Under the hood, everything lives in `~/.config/petal/` and
reloads live when saved:

- **`settings.json`**: appearance (`dockColor`, `dockOpacity`, `dockRadius`, `iconSize`,
  `accentColor`, `font`, `popupColor`, …) and feature switches (`bounce`, `badges`, `previews`,
  `appGlow`, `autoUpdate`, …), plus the chat panel's `chatModel`, `chatEffort` and
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

- **`instructions.md`** (optional): your own standing instructions for the AI, added to every
  chat ("Always answer in Turkish", "I use Helium, not Chrome", …).

### The Petal MCP server

`plugin/mcp/petal-mcp.py` is a dependency-free MCP server with tools to read Petal's state, change
settings and modes, move the dock and reload it. The chat panel connects it automatically, and
`install.sh` registers it with Claude Code and Codex, so any session of theirs can change your dock
too. (On a Mac the same tools are Petal.app itself.)

## The `petal` command

```
petal mode <id>   switch this workspace to a mode
petal current     print this workspace's mode
petal modes       list modes and their apps
petal ask         open the AI panel
petal search      open the add-apps search
petal settings    open the settings menu
petal edit        edit modes.json
petal restart     restart Omarchy's shell (reloads Petal)
petal update      update from GitHub Releases (--check to only look)
petal version     the installed version
```

## Privacy

Petal has no server and no analytics, and sends nothing anywhere by itself. What you ask the AI,
and what it looks at to answer, goes to it through your own Claude Code or Codex.

On Omarchy, with sorting on, the app name and window title of windows Petal doesn't recognize, and
the app, title and text of notifications it holds, go to the AI the same way; turn sorting off to
keep them local. On the Mac, what's in the vault stays in your Keychain and is never shown to the
AI, and apps you mark as private are never looked into.

## Troubleshooting

- **Dock doesn't show:** `omarchy restart shell`, then check the log:
  `quickshell log "$(ls -td /run/user/$UID/quickshell/by-id/*/ | head -1)log.qslog" | grep -i petal`
- **AI features do nothing:** run `petal doctor`, and check that `claude -p hi` (or `codex`) works in a terminal.
- **Usage ring missing:** it uses Omarchy's `omarchy-agent-usage-claude`; run it to see if it works.
- **Two docks:** turn off Omarchy's built-in dock.

## Uninstall

```bash
./uninstall.sh && omarchy restart shell
```

## Credits

Made by [Edgetr](https://edgetr.tech) in Istanbul, with Claude. Inspired by an AI-native
focus dock idea from Thariq. Claude is a trademark of Anthropic and Codex of OpenAI; Petal is not
affiliated with Anthropic, OpenAI, Apple or Omarchy.

MIT licensed.
