#!/usr/bin/env bash
# Builds Petal.app for macOS 26 and later into macos/build/.
#
#   macos/build.sh                    a release build, signed ad hoc
#   PETAL_SIGN_IDENTITY=<hash> ...    signed with that certificate instead
#
# Petal has no Apple Developer ID, so a downloaded Petal.app is opened once through System Settings > Privacy &
# Security > Open Anyway. Signing with one stable certificate (even a self-made one) keeps the permissions macOS
# grants (Accessibility, Screen Recording) across updates; an ad hoc signature changes with every build.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VERSION="$(cat VERSION)"
IDENTITY="${PETAL_SIGN_IDENTITY:--}"
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
# Claude's Petal tools: the same MCP server as on Omarchy, which knows it's on a Mac.
mkdir -p "$APP/Contents/Resources/mcp"
cp "$ROOT/plugin/mcp/petal-mcp.py" "$APP/Contents/Resources/mcp/petal-mcp.py"

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
echo "built $APP $VERSION ($( [ "$IDENTITY" = "-" ] && echo "ad hoc" || echo "signed"))"
