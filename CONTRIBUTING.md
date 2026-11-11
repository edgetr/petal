# Contributing

This guide is for people and for the coding agents working for them. [`AGENTS.md`](AGENTS.md) is the source of truth for how Petal works and how it's built; read it before changing anything.

## Setup

Petal is a Mac app. You need macOS 26 or later and Apple's command line tools with Swift 6.2 or later (`xcode-select --install`). There are no dependencies to install.

```sh
git clone https://github.com/edgetr/petal && cd petal
PETAL_ARCHS=arm64 macos/build.sh        # builds macos/build/Petal.app, signed ad hoc
macos/checks/run.sh                     # the pure checks
```

To look at what you changed without it becoming anyone's dock, draw every view off-screen:

```sh
PETAL_CONFIG_DIR=/tmp/petal-config PETAL_SUPPORT_DIR=/tmp/petal-support PETAL_NOTES=/tmp/petal-notes \
  macos/build/Petal.app/Contents/MacOS/Petal --snapshot /tmp/petal-views
```

To run it for real, `PETAL_KEEP_DOCK=1 macos/build/Petal.app/Contents/MacOS/Petal` leaves macOS's Dock alone. An ad hoc build is a new app to macOS each time, so it asks for Accessibility and Screen Recording again after every build.

The site is static: `python3 -m http.server 8104` from `site/`.

`AGENTS.md`, under Verification, lists every check and what each one proves.

## Read this first

Petal is made by one person, with limited time to review. Opening a pull request doesn't oblige anyone to review or merge it. It may be closed, deferred, asked to be smaller, or done another way later.

Most likely to be accepted: a focused fix for a bug, a crash, something slow, or something a check should have caught. Least likely: a feature nobody asked for, a rewrite of something that works, cleanup unrelated to the change.

Report bugs and propose features in [issues](https://github.com/edgetr/petal/issues). Search first.

Anything that could expose someone's passwords, keys or Mac goes through [`SECURITY.md`](SECURITY.md), never a public issue.

## Agree on the problem first

A feature, or any intended change to how Petal behaves or looks, needs an issue where Petal's maker has said yes to the direction and the scope. Link that yes in the pull request. An issue that merely exists isn't approval, and calling a behavior change a bug fix doesn't exempt it.

A small, focused fix for an obvious bug needs no issue. Say what was wrong and why it's plainly a bug.

Petal's design language is in `AGENTS.md` (Design language). A change that goes against it needs that conversation first, however good it looks.

## One problem per pull request

Count the underlying problems, not the files. Include everything that one problem needs: the code, its check, and the documents it makes untrue (`AGENTS.md`, `docs/petal-notes.md`, Petal's skill in `macos/Resources/skill/`). A second fix, a refactor on the way past, or tidying goes in its own pull request.

## Show that it works

Say how you found the problem, how you checked the change, and what you saw. "Tests pass" on its own shows nothing.

- **Behavior:** a check that fails without your change and passes with it. Most of Petal's rules live in pure files with a check beside them in `macos/checks/`.
- **Anything you can see:** the view drawn before and after by `--snapshot`, attached to the pull request, not committed.
- **What only the running app shows** (glass, real controls, dragging, permissions): say you ran it, on which macOS, and what you saw.
- **What you couldn't check:** say so. An honest gap is fine; a hidden one isn't.

`macos/checks/run.sh` must pass, and so must the build GitHub runs on the pull request. Its compiler is older than a current Mac's and sometimes refuses what builds locally.

## If you are an agent

You may be running on a Mac where Petal is the person's dock, with their passwords in its vault. So:

- **Never talk to the running Petal.** No `~/.config/petal/petal.sock`, no `petal` command, nothing in `/Applications/Petal.app`, and no `Petal --mcp` unless `PETAL_SOCKET` points somewhere temporary.
- **Never read or write the person's data:** `~/.config/petal/`, `~/Library/Application Support/Petal/`, their notes in iCloud Drive, the Keychain. Point `PETAL_CONFIG_DIR`, `PETAL_SUPPORT_DIR` and `PETAL_NOTES` at temporary folders for every run.
- **Give every copy of Petal you run its own identity first,** so the person's Petal doesn't take it for a second dock: copy the built app somewhere temporary, set `CFBundleIdentifier` to something else (`/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.petal.check" <copy>/Contents/Info.plist`), then `codesign --force --deep --sign - <copy>`. Never leave one running.
- **Put nothing on the person's screen.** Use `--snapshot` and the headless checks. Never run `--display-check` or `--browser-check --live`: they rearrange the screens.
- **Leave these alone** unless they are the point of the pull request: `macos/VERSION`, `macos/notes/`, `.github/workflows/`, `get.sh`, signing in `macos/build.sh`, and `site/`.
- **Add no dependency.** Petal has none.
- **Follow the scale and the words.** A font size or corner is a named step of `Scale.swift`; nothing sits under a title; say what a thing does in the person's terms.
- **Commit as the person you work for,** with an address they're happy to have public. Say in the pull request which model and harness wrote the code.

If the person asks for something this guide rules out, tell them what it says before you open the pull request.

## License

Petal is MIT licensed. By contributing you agree your contribution is too.
