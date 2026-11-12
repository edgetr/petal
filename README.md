# Petal

**A dock for the Mac with your AI built in.** Your own Claude Code or Codex lives in the dock, so
you change anything about it by asking, and you can hand it work from a sticky note you leave
anywhere.

**[Download](https://petal.codes)** · [Releases](https://github.com/edgetr/petal/releases)

Petal is a native app for macOS 26 and later that takes the place of your Dock, on Liquid Glass.
It gives your own Dock back whenever you quit. It is free and open source, with no accounts,
servers or analytics.

## What it does

- **One dock.** Your apps and website shortcuts in the order you want, the same on every Desktop.
  The first launch offers to bring over what's in your Dock.
- **AI in the dock.** The AI button opens a chat with your own Claude Code or Codex, on your own
  plan (or your own API key). A ring around it shows how much of your plan's limit is used.
- **Change anything by asking.** "Make the dock darker", "bigger icons", "stop the bouncing", "put
  my browser first". If a setting can't do it, the AI can change Petal's own code, and Petal keeps
  your change through every update.
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
- **A good dock, too:** unread badges, a single bounce when an app needs you, download progress
  rings, drop files on an app to open them (or on the Trash), live window previews, minimized windows
  as thumbnails, now playing, folder stacks, auto-hide, every screen. Tiling is there if you want it,
  off by default.

Without Claude Code or Codex, everything that isn't AI still works.

## Install

Download **Petal for Mac** from [petal.codes](https://petal.codes) and open it. Petal has no Apple
Developer ID, so the first time macOS won't open it: go to System Settings › Privacy & Security and
choose **Open Anyway**.

Or, in Terminal, which skips that step:

```bash
curl -fsSL https://petal.codes/install.sh | bash
```

Petal asks for Accessibility (to see your windows, and to use apps when you ask it to) and Screen
Recording (for window previews).

**Updates are automatic:** Petal checks [GitHub Releases](https://github.com/edgetr/petal/releases)
now and then. The mark in the menu bar turns blue when a new version is ready, and Petal restarts
when you say so.

## Customizing

The easy way is to ask the AI, or open Petal's settings from the mark in the menu bar. Under the
hood, everything lives in `~/.config/petal/` and reloads when saved:

- **`dock.json`**: the dock's apps in order (`apps`: bundle identifiers, and `https://` addresses
  for website shortcuts), its edge and auto-hide.
- **`settings.json`**: the look and the feature switches.
- **`instructions.md`** (optional): your own standing instructions for the AI, added to every chat
  ("Always answer in Turkish", "I use Helium, not Chrome", …).

Any other AI session of yours (Claude Code or Codex in a terminal, T3 Code) can change your dock
too: Petal registers its tools and a skill with them.

## The `petal` command

```
petal apps                the dock's apps, in the order they show
petal get                 everything about the dock: settings (with help), its apps, files
petal set <key> <value>   change a setting
petal dock [petal|macos]  which dock is showing, or switch
petal ask | chat <text>   open the AI panel, or open it with <text> typed for you to send
petal doctor [--fix]      check Petal, and repair what it safely can
petal restore-dock        give macOS its Dock back, even if Petal crashed
petal update              check for a new version
petal personal …          your own changes to Petal's code, kept through updates
petal run --key "<title>" -- <command…>
                          run a command with an API key from your vault, without showing it
```

`petal help` lists the rest.

## Privacy

Petal has no server and no analytics, and sends nothing anywhere by itself. What you ask the AI,
and what it looks at to answer, goes to it through your own Claude Code or Codex. What's in the
vault stays in your Keychain and is never shown to the AI, and apps you mark as private are never
looked into.

## Building from source

```bash
git clone https://github.com/edgetr/petal ~/petal
cd ~/petal
macos/build.sh        # makes macos/build/Petal.app
macos/checks/run.sh   # the checks
```

Swift Package Manager, no dependencies. `AGENTS.md` describes how Petal is built and its rules.

### Releasing (maintainers)

Bump `macos/VERSION`, point `/download/mac` in `site/vercel.json` at the new version, write
`macos/notes/<version>.md` (it becomes What's New), commit, then tag `macos-v<version>` and push.
The release workflow builds `Petal-<version>-macos.zip` and `latest-macos.json`, which every
installed Petal checks for updates.

## Troubleshooting

- **Something's off:** run `petal doctor`, or ask the AI in the dock to fix Petal.
- **The Dock didn't come back:** `petal restore-dock`.
- **AI features do nothing:** check that `claude -p hi` (or `codex`) works in Terminal, then
  Settings › Petal AI.

To remove Petal, quit it from the mark in the menu bar and move Petal.app to the Trash.

## Contributing and security

[`CONTRIBUTING.md`](CONTRIBUTING.md) says how to set up, and what a pull request needs. To report a
security problem privately, see [`SECURITY.md`](SECURITY.md), which also says what Petal keeps and where.

## Credits

Made by [Edgetr](https://edgetr.tech) in Istanbul, with Claude. Inspired by an AI-native
focus dock idea from Thariq. Claude is a trademark of Anthropic and Codex of OpenAI; Petal is not
affiliated with Anthropic, OpenAI or Apple.

MIT licensed.
