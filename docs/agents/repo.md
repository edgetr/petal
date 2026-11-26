Read this before changing the fleet, a dependency, the installer (`get.sh`), the icon, the files in `~/.config/petal/`, signing, the workflows or anything about a release.

# Petal: fleet, stack, layout and releases

## Fleet

Petal is developed, built and run on the owner's Mac (Gökay MacBook Pro), in `~/petal`. GitHub is the only way code moves between machines. T3 may list other linked environments; agents don't use them.

- **Where checkouts live:** every project directly in the home folder (`~/petal`, `~/edgetr`, …). Never in `~/Documents`: macOS keeps it from background jobs, so `tools/fleet` can't sync it.
- **Sync through GitHub:** `tools/fleet` keeps the owner's checkouts fast-forwarded to GitHub, at login and every 5 minutes, on each machine it is installed on (`tools/fleet install`, once per machine: launchd on macOS, a systemd user timer elsewhere). It fetches every `edgetr` checkout and fast-forwards it. It never pushes, and it leaves alone a branch that has diverged, a merge or rebase in progress, and a pull that would overwrite uncommitted changes. So work reaches another machine only once it is committed and pushed; `tools/fleet status` shows what's behind or ahead. Don't copy files between machines.
- **Per-machine setup** (T3 project icons, `~/.config/petal/`, `tools/fleet install`) isn't in the repository: change it on the machine.

## Stack

| Layer | Decision |
| --- | --- |
| AI | the user's own `claude` or `codex` CLI. Quick calls (routines' sorting and helpers in notes): `claude -p --model haiku --effort low`, or `codex exec --json --ephemeral --sandbox read-only` at low effort. Chat: stream-json Claude Code sessions, or `codex exec --json` resumed by thread id (without Full access in a scratch folder, `--sandbox workspace-write`), with Petal's MCP tools approved ahead (codex exec can't ask) |
| MCP | Petal itself: `Petal --mcp` speaks MCP on stdin and stdout; the tools are listed in `macos/Resources/mcp/tools.json` |
| Scripts | Bash (`get.sh`, `macos/build.sh`, `macos/checks/run.sh`, `tools/fleet`) and Python 3 standard library (`macos/Resources/personal/petal-personal`, run with the python3 of Apple's command line tools; `brand/icon.py`). Building Petal needs no Python |
| Website | static `site/` (no build step, self-hosted Geist), Vercel project `petal-dock` |
| App | Swift and SwiftUI with macOS's own Liquid Glass, macOS 26 and later, built with Swift Package Manager (`macos/`), no dependencies yet |
| Signing | no Apple Developer ID. Every release is signed with Petal's own self-made certificate, "Petal (Edgetr)" (repository secrets `MACOS_SIGNING_P12`, `MACOS_SIGNING_PASSWORD`; also in the owner's login keychain, which `build.sh` uses), so macOS knows each update as the same app and keeps the permissions people granted. Never replace it: a new certificate makes everyone grant Accessibility and Screen Recording again, and every installed Petal and `get.sh` would refuse the release (they install only what that certificate signed: `UpdateTrust.swift`). A zip opened from a browser needs System Settings > Privacy & Security > Open Anyway once |
| Release | GitHub Actions with the workflow's own `GITHUB_TOKEN` only |

Add no Swift package and no other dependency without the owner. Python stays standard library.

## Architecture

- `brand/icon.py`: draws Petal's icon and writes every copy of it: the flat ones (`site/icon.svg`, the site's PNGs and `site/favicon.ico`) and the app icon (`brand/Petal.icon` for Icon Composer and Xcode, compiled to `brand/macos/Assets.car` and `Petal.icns`, with `brand/previews/` of every appearance). Change the icon there, never by hand; it needs Xcode.
- **User data:** `~/.config/petal/` holds `settings.json`, `instructions.md`, `dock.json` (the dock's apps and place), `memory.json` and `routines.json`, and `instructions.draft.md`: the notes typed in Settings, kept only while they and a change made elsewhere wait for the person to pick. Petal reloads them live. A new install starts with an empty dock and the offer to import macOS's. The dock's apps are `dock.json`'s `apps` (bundle identifiers such as `com.apple.Safari`, and `https://` addresses), changed by editing that file or with `petal_set_dock`. When the owner asks to change their dock, change these files (or use Petal's tools); Petal reloads them.
- **Install:** `get.sh` (served as https://petal.codes/install.sh) installs Petal.app from the newest `macos-v` release into /Applications, or `~/Applications` when that can't be written, once the download matches its checksum, is signed with Petal's certificate and is the version its release names. A download by curl isn't quarantined, so it opens without Gatekeeper's prompt; a zip downloaded in a browser needs System Settings > Privacy & Security > Open Anyway once. Anywhere but on a Mac it says Petal is for the Mac and changes nothing.

## Releases

- **Releases:** bump `macos/VERSION`, tag `macos-vX.Y.Z` to match, push the tag. `.github/workflows/release-macos.yml` checks the tag against `macos/VERSION`, builds `Petal-<v>-macos.zip` and `latest-macos.json`, and publishes the GitHub Release as the latest. A release also needs `/download/mac` in `site/vercel.json` pointed at its zip (the workflow refuses the tag otherwise), a build signed with Petal's certificate (the workflow checks it as an installed Petal would, and publishes nothing it would refuse) and `macos/notes/<version>.md`, which becomes the release's text and What's New in the app: written for the person, by what they can do now first. A line `<!-- Release page only: the app leaves out what follows. -->` ends what the app shows; what only someone downloading needs (macOS 26, Open Anyway) goes after it. Only the newest three releases are kept: the workflow deletes older ones after publishing, and leaves their git tags (the personal source takes a version's source from its tag). Released Petals and `get.sh` find a release by the `macos-v` tag prefix and its `latest-macos.json`: never rename either. Every installed Petal updates itself within hours, so releasing is outward-facing: only when the owner says to.
