#!/usr/bin/env bash
# Builds Petal.app for macOS 26 and later into macos/build/.
#
#   macos/build.sh                    a release build, signed with Petal's certificate if it's in a keychain
#   PETAL_SIGN_IDENTITY=<hash> ...    signed with that certificate instead
#   PETAL_ARCHS=arm64 ...             only for these architectures (a personal build: this Mac's own, and quicker)
#
# Petal has no Apple Developer ID. Its own self-made certificate, "Petal (Edgetr)", signs every release (the release
# workflow gets it from the repository's secrets), so macOS knows each update as the same app and keeps the
# permissions people gave it (Accessibility, Screen Recording). Without it the build is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VERSION="$(cat VERSION)"
IDENTITY="${PETAL_SIGN_IDENTITY:-$(security find-identity 2>/dev/null | awk '/"Petal \(Edgetr\)"/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
APP="build/Petal.app"

ARCH_FLAGS=()
for arch in ${PETAL_ARCHS:-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$arch"); done

log="$(mktemp)"
if ! swift build -c release "${ARCH_FLAGS[@]}" >"$log" 2>&1; then
  grep -E "error" "$log" || tail -20 "$log"
  rm -f "$log"
  echo "build failed" >&2
  exit 1
fi
grep -E "warning: " "$log" | grep -v x86_64 || true
rm -f "$log"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/Petal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Petal"
# The icon: Assets.car holds every appearance (light, dark, tinted, clear); Petal.icns is the fallback.
cp "$ROOT/brand/macos/Assets.car" "$ROOT/brand/macos/Petal.icns" "$APP/Contents/Resources/"
# Everything in macos/Resources goes into the app as it is: the AI apps' marks (claude.svg, openai.svg); the
# Public Suffix List, which says which names anyone can register under (co.uk, github.io), so the vault fills a login
# only on its own site (VaultSite); the AI's tools, their names, descriptions and input schemas (mcp/tools.json;
# `Petal --mcp` serves them); the person's own changes to Petal's code kept through updates (personal/petal-personal;
# Personal.swift runs it); and Petal's skill for Claude Code and Codex (skill/SKILL.md), which Petal copies into
# their skills folders.
cp -R "$ROOT/macos/Resources/." "$APP/Contents/Resources/"
# Each version's notes (macos/notes/<version>.md, also each release's text), so What's New opens after an update
# with no network (ReleaseNotes reads Resources/notes/).
mkdir -p "$APP/Contents/Resources/notes"
cp "$ROOT"/macos/notes/*.md "$APP/Contents/Resources/notes/"

# The commit it's built from: `petal personal` takes Petal's source from it (a release's tag has the same one).
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>tech.edgetr.petal</string>
  <key>CFBundleName</key><string>Petal</string>
  <key>CFBundleDisplayName</key><string>Petal</string>
  <key>CFBundleExecutable</key><string>Petal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>PetalSourceCommit</key><string>$COMMIT</string>
  <key>CFBundleIconFile</key><string>Petal</string>
  <key>CFBundleIconName</key><string>Petal</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Edgetr. MIT License.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Ask Petal AI</string></dict>
      <key>NSMessage</key><string>askPetal</string>
      <key>NSPortName</key><string>Petal</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Add to Petal AI</string></dict>
      <key>NSMessage</key><string>addToPetal</string>
      <key>NSPortName</key><string>Petal</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>tech.edgetr.petal.note</string>
      <key>UTTypeDescription</key><string>Petal Note</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key><string>When you drop a note on Calendar in the dock, Petal adds it as an event, after asking you.</string>
  <key>NSAppleEventsUsageDescription</key><string>Petal reads which site a browser tab is on, for notes stuck to a tab and for Petal AI. It also shows what's playing in Music and Spotify, and opens and empties the Trash in Finder.</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --entitlements Petal.entitlements --sign "$IDENTITY" "$APP" 2>/dev/null
codesign --verify --strict "$APP"
echo "built $APP $VERSION ($( [ "$IDENTITY" = "-" ] && echo "signed ad hoc" || echo "signed by $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"))"
