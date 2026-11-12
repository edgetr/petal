# Security

Petal holds people's passwords and is allowed to read and operate their Mac, so a hole in it matters. This page says how to report one, and what Petal keeps and where.

## Reporting a problem

Report it privately, through GitHub: [github.com/edgetr/petal/security/advisories/new](https://github.com/edgetr/petal/security/advisories/new). Only Petal's maker sees it.

Please don't open a public issue or pull request for anything that could expose someone's passwords, keys, notes or Mac before it's fixed.

Say which Petal you have (Settings › About), which macOS, what you did and what happened. Steps someone else can follow are worth more than a description.

Petal is made by one person, who reads every report. There is no bounty.

## Which versions get fixes

The newest release. Petal updates itself, so a fix reaches people as a new release, not as a patch to an old one.

## What Petal keeps, and where

Petal has no server and no analytics. Everything below is on the person's own Mac.

| What | Where | Notes |
| --- | --- | --- |
| The vault: logins, contact info, addresses, payment info, API keys | The Mac's Keychain, service `tech.edgetr.petal.vault`, one item each | Never in a file. Readable only while the Mac is unlocked. Petal doesn't sync it anywhere. Showing a saved secret, or exporting, asks for Touch ID or the Mac's password. |
| An API key for Petal's own AI runs | The Keychain, service `tech.edgetr.petal.api` | Handed only to the AI app Petal starts, in its environment. |
| Settings, the dock's apps, what Petal AI remembers, routines | Plain files in `~/.config/petal/` | Not secrets, and not encrypted. |
| Notes | Markdown files in iCloud Drive (`Petal Notes`) | Protected as any file there is; Petal doesn't encrypt them. |
| Chats, what Petal AI did, agents' grants | `~/Library/Application Support/Petal/` | A grant holds no secret. What Petal AI did is put through the vault's redaction before it's kept. |

The AI never sees a password, a card number, a security code or a key. Petal fills those itself, decides from what it reads of the page or app (never from what the AI says) whether a login belongs there, asks first anywhere else, and takes every vault secret out of what the AI is shown.

AI features talk to Anthropic or OpenAI through the person's own Claude Code or Codex, under that app's own sign-in.

## What macOS lets Petal do

With the person's permission: Accessibility (reading and operating windows), Screen Recording (stills of windows), and Automation of browsers and music players. Other programs reach Petal through a socket in `~/.config/petal/` that only the person's own account can open; an agent outside Petal asks on a card before it uses anything from the vault.

## Installs and updates

Every release is signed with Petal's own certificate, "Petal (Edgetr)". It is not an Apple Developer ID and Petal is not notarized, so macOS asks once before opening a copy downloaded in a browser.

Petal, and the installer at `petal.codes/install.sh`, install a download only when it matches its release's checksum and is signed, whole, with that certificate (from Petal 2.1.3). The signing key is not in this repository.

With changes of the person's own to Petal's code (`petal personal`), an update is built on their Mac from the source that signed release says it was built from.

## Worth reporting

- A vault secret reaching the AI, a web page, an agent, another app, a log or a file.
- A login, card or key filled somewhere it doesn't belong.
- Something on the Mac driving Petal, or reading from it, without the person's say.
- An update or install accepting something Petal's maker didn't sign.
- A page, a note, a file or a tool's answer making Petal AI act without the card it should have asked on.

## Known limits

These are how Petal works today, not holes:

- A program already running as the person can read their files, including Petal's settings and notes.
- A Private notebook is kept from Petal AI and from Petal's own pictures; it is not protection from another app recording the screen.
- `petal run` takes a key out of what a command prints. A command written to leak a key in another form still can.
- An agent's Always for a project covers anything that can start or set up that agent in that project.
- Full access and an earlier Always for Petal AI also cover the person's own Claude Code and Codex outside Petal, and so whatever those run.
