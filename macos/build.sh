#!/usr/bin/env bash
# Builds Petal.app for macOS 26 and later into macos/build/.
#
#   macos/build.sh                    a release build, signed with Petal's certificate if it's in a keychain
#   PETAL_SIGN_IDENTITY=<hash> ...    signed with that certificate instead
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

log="$(mktemp)"
if ! swift build -c release --arch arm64 --arch x86_64 >"$log" 2>&1; then
  grep -E "error" "$log" || tail -20 "$log"
  rm -f "$log"
  echo "build failed" >&2
  exit 1
fi
grep -E "warning: " "$log" | grep -v x86_64 || true
rm -f "$log"
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Petal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Petal"
# The icon: Assets.car holds every appearance (light, dark, tinted, clear); Petal.icns is the fallback.
cp "$ROOT/brand/macos/Assets.car" "$ROOT/brand/macos/Petal.icns" "$APP/Contents/Resources/"
cp "$ROOT/defaults/modes-macos.json" "$APP/Contents/Resources/modes.json"
cp "$ROOT/plugin/assets/claude.svg" "$APP/Contents/Resources/claude.svg"
# Claude's Petal tools run inside Petal (`Petal --mcp`); their names, descriptions and settings come from
# petal-mcp.py, so Omarchy and the Mac describe them the same way.
mkdir -p "$APP/Contents/Resources/mcp"
python3 -I "$ROOT/plugin/mcp/petal-mcp.py" --describe > "$APP/Contents/Resources/mcp/tools.json"
# The person's own changes to Petal's code, kept through updates (`petal personal`; Personal.swift runs it).
mkdir -p "$APP/Contents/Resources/personal"
cp "$ROOT/bin/petal-personal" "$APP/Contents/Resources/personal/petal-personal"
# Petal's skill for Claude Code and Codex, which Petal copies into their skills folders.
mkdir -p "$APP/Contents/Resources/skill"
cp "$ROOT/plugin/skill/SKILL.md" "$APP/Contents/Resources/skill/SKILL.md"

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
  <key>CFBundleIconFile</key><string>Petal</string>
  <key>CFBundleIconName</key><string>Petal</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Edgetr. MIT License.</string>
  <key>NSAppleEventsUsageDescription</key><string>Petal shows what's playing in Music and Spotify, and opens and empties the Trash in Finder.</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --entitlements Petal.entitlements --sign "$IDENTITY" "$APP" 2>/dev/null
codesign --verify --strict "$APP"
echo "built $APP $VERSION ($( [ "$IDENTITY" = "-" ] && echo "signed ad hoc" || echo "signed by $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"))"
