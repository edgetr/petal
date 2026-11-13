#!/usr/bin/env bash
# Installs Petal: Petal.app from the newest release, into /Applications (or ~/Applications).
#
#   curl -fsSL https://petal.codes/install.sh | bash
#
# Once installed, Petal updates itself. A download by curl isn't quarantined, so macOS opens it without the
# "unidentified developer" prompt. JSON is read with macOS's own JavaScript: a Mac needs nothing installed for this.
#
#   PETAL_APPS=<folder>            install there instead of /Applications
#   PETAL_NO_OPEN=1                don't open Petal afterwards
#   PETAL_MACOS_MANIFEST=<url>     read this latest-macos.json instead of the newest release's
set -euo pipefail

REPO="edgetr/petal"
MAKER='identifier "tech.edgetr.petal" and certificate root = H"29feb33bdddb5686cbc597ca9706b0b8a6f3b36d"'

fail() { echo "Petal: $1" >&2; exit 1; }

[[ $(uname) == Darwin ]] || fail "Petal is for the Mac (macOS 26 or later)."

json() { osascript -l JavaScript -e "function run(argv) { var d = JSON.parse(argv[0]); return ($1); }" "$2"; }

# Petal's releases are the tags macos-v<version>; each carries latest-macos.json: its version, zip and checksum.
manifest="${PETAL_MACOS_MANIFEST:-}"
if [[ -z $manifest ]]; then
  releases="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100")" || fail "couldn't reach GitHub"
  manifest="$(json "((d.find(function (r) { return r.tag_name.indexOf('macos-v') === 0 && !r.draft && !r.prerelease; }) || {assets: []}).assets.filter(function (a) { return a.name === 'latest-macos.json'; })[0] || {}).browser_download_url || ''" "$releases")"
fi
[[ -n $manifest ]] || fail "couldn't find Petal's newest release on GitHub"
latest="$(curl -fsSL "$manifest")" || fail "couldn't reach GitHub"
version="$(json 'd.version' "$latest")"
url="$(json 'd.url' "$latest")"
sha="$(json 'd.sha256' "$latest")"
# Numbers with dots only (as UpdateTrust.plainVersion in the app): the version is shown, and checked against the app.
[[ $version =~ ^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$ ]] || fail "the newest release's version isn't one this installer can read"

dest="${PETAL_APPS:-/Applications}"
if [[ ! -w $dest ]]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Petal ${version}…"
curl -fsSL "$url" -o "$tmp/Petal.zip" || fail "couldn't download Petal $version"
[[ $(shasum -a 256 "$tmp/Petal.zip" | cut -d' ' -f1) == "$sha" ]] || fail "the download didn't match its checksum"
ditto -x -k "$tmp/Petal.zip" "$tmp/unpacked" || fail "couldn't unpack Petal $version"
[[ -d $tmp/unpacked/Petal.app ]] || fail "the download had no Petal.app"
# The checksum came with the download. The signature can't be made by whoever made the download: every release is
# signed with Petal's own certificate, by this hash (the same words as UpdateTrust.swift in the app).
codesign --verify --deep --strict -R="$MAKER" "$tmp/unpacked/Petal.app" 2>/dev/null || fail "the download isn't signed by Petal's maker"
# And it's the very version its release said, not another (older) build of the maker's under that number.
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$tmp/unpacked/Petal.app/Contents/Info.plist" 2>/dev/null) == "$version" ]] \
  || fail "the download isn't the Petal $version its release said"

# A Petal that's running quits first, so the new one can take its place.
if pgrep -xq Petal; then osascript -e 'tell application id "tech.edgetr.petal" to quit' >/dev/null 2>&1 || true; sleep 1; fi
rm -rf "$dest/Petal.app"
ditto "$tmp/unpacked/Petal.app" "$dest/Petal.app"
xattr -dr com.apple.quarantine "$dest/Petal.app" 2>/dev/null || true
if [[ -n ${PETAL_NO_OPEN:-} ]]; then
  echo "Petal $version is in $dest."
else
  open "$dest/Petal.app"
  echo "Petal $version is in $dest and open. Its welcome window lets you bring your Dock along."
fi
