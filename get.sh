#!/usr/bin/env bash
# Petal installer and updater, from GitHub Releases.
#
#   curl -fsSL https://petal-dock.vercel.app/install.sh | bash   # install
#   petal update            # update now
#   petal update --check    # is there a newer version?
#
# Releases live in ~/.local/share/petal/releases/<version>, with
# ~/.local/share/petal/current pointing at the one in use. With --auto or
# --check it prints one JSON line (for the dock), otherwise plain text.
set -euo pipefail

REPO="edgetr/petal"
ROOT="${PETAL_HOME:-$HOME/.local/share/petal}"
mode="install"
case "${1:-}" in
  --update) mode="update" ;;
  --auto) mode="auto" ;;
  --check) mode="check" ;;
esac

say() { if [[ $mode == install || $mode == update ]]; then echo "$@"; fi; }
emit() { if [[ $mode == auto || $mode == check ]]; then echo "$1"; fi; }
fail() { emit "{\"status\":\"error\",\"message\":\"$1\"}"; say "Petal: $1" >&2; exit 1; }

# Petal for macOS: Petal.app from the newest macos-v release, into /Applications (or ~/Applications). A download
# by curl isn't quarantined, so macOS opens it without the "unidentified developer" prompt. JSON is read with
# macOS's own JavaScript, since a Mac without developer tools has no python3.
if [[ $(uname) == Darwin ]]; then
  json() { osascript -l JavaScript -e "function run(argv) { var d = JSON.parse(argv[0]); return ($1); }" "$2"; }
  manifest="${PETAL_MACOS_MANIFEST:-}"
  if [[ -z $manifest ]]; then
    releases="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30")" || fail "couldn't reach GitHub"
    manifest="$(json "((d.find(function (r) { return r.tag_name.indexOf('macos-v') === 0 && !r.draft && !r.prerelease; }) || {assets: []}).assets.filter(function (a) { return a.name === 'latest-macos.json'; })[0] || {}).browser_download_url || ''" "$releases")"
  fi
  [[ -n $manifest ]] || fail "Petal for macOS has no release yet"
  latest="$(curl -fsSL "$manifest")" || fail "couldn't reach GitHub"
  version="$(json 'd.version' "$latest")"
  url="$(json 'd.url' "$latest")"
  sha="$(json 'd.sha256' "$latest")"
  dest="${PETAL_APPS:-/Applications}"
  if [[ ! -w $dest ]]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  say "Downloading Petal $version for macOS…"
  curl -fsSL "$url" -o "$tmp/Petal.zip" || fail "couldn't download Petal $version"
  [[ $(shasum -a 256 "$tmp/Petal.zip" | cut -d' ' -f1) == "$sha" ]] || fail "the download didn't match its checksum"
  ditto -x -k "$tmp/Petal.zip" "$tmp/unpacked" || fail "couldn't unpack Petal $version"
  [[ -d $tmp/unpacked/Petal.app ]] || fail "the download had no Petal.app"
  osascript -e 'tell application id "tech.edgetr.petal" to quit' >/dev/null 2>&1 || true
  rm -rf "$dest/Petal.app"
  ditto "$tmp/unpacked/Petal.app" "$dest/Petal.app"
  xattr -dr com.apple.quarantine "$dest/Petal.app" 2>/dev/null || true
  [[ -n ${PETAL_NO_OPEN:-} ]] || open "$dest/Petal.app"
  say "Petal $version is in $dest and open. Its welcome window lets you bring your Dock along."
  exit 0
fi

for tool in curl tar python3 sha256sum; do
  command -v "$tool" >/dev/null || fail "missing $tool"
done

# A dock linked to a source checkout (a developer install) updates with git.
link="$(readlink -f "$HOME/.config/omarchy/plugins/egesuren.petal" 2>/dev/null || true)"
if [[ $mode != install && -n $link && $link != "$ROOT"/* ]]; then
  emit '{"status":"dev"}'
  say "Petal is installed from source ($link); update it with git pull."
  exit 0
fi

# Ask the API for the newest tag (the /latest/download link is cached for a
# few minutes after a release), then read that release's latest.json.
tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || true)"
if [[ -n $tag ]]; then
  latest="$(curl -fsSL "https://github.com/$REPO/releases/download/$tag/latest.json")" || fail "couldn't reach GitHub"
else
  latest="$(curl -fsSL "https://github.com/$REPO/releases/latest/download/latest.json")" || fail "couldn't reach GitHub"
fi
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" <<<"$latest"; }
version="$(field "d['version']")"
url="$(field "d['linux']['url']")"
sha="$(field "d['linux']['sha256']")"

current=""
if [[ -f $ROOT/current/plugin/manifest.json ]]; then
  current="$(python3 -c "import json; print(json.load(open('$ROOT/current/plugin/manifest.json'))['version'])")"
fi

newest="$(printf '%s\n%s\n' "$version" "${current:-0}" | sort -V | tail -1)"
if [[ -n $current && ($current == "$version" || $newest == "$current") ]]; then
  emit "{\"status\":\"current\",\"version\":\"$current\"}"
  say "Petal $current is up to date."
  exit 0
fi
if [[ $mode == check ]]; then
  emit "{\"status\":\"available\",\"version\":\"$version\",\"current\":\"$current\"}"
  exit 0
fi

say "Downloading Petal $version…"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/petal.tar.gz" || fail "download failed"
echo "$sha  $tmp/petal.tar.gz" | sha256sum -c --quiet - || fail "checksum mismatch"

mkdir -p "$ROOT/releases"
rm -rf "$ROOT/releases/$version"
mkdir -p "$ROOT/releases/$version"
tar -xzf "$tmp/petal.tar.gz" -C "$ROOT/releases/$version" --strip-components=1
ln -sfn "releases/$version" "$ROOT/current.new"
mv -T "$ROOT/current.new" "$ROOT/current"

"$ROOT/current/install.sh" >/dev/null

# Keep the two newest releases.
ls -1 "$ROOT/releases" | sort -V | head -n -2 | while read -r old; do rm -rf "$ROOT/releases/$old"; done

emit "{\"status\":\"updated\",\"version\":\"$version\",\"from\":\"$current\"}"
if [[ $mode == install && -z $current ]]; then
  say "Petal $version installed."
  command -v omarchy >/dev/null && omarchy restart shell >/dev/null 2>&1 || true
  say "Turn off Omarchy's own dock if it's on, and click the Claude button to get started."
else
  say "Petal updated to $version. Restart the shell to finish: omarchy restart shell"
fi
