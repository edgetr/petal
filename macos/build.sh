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

swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Petal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Petal"
# The icon: Assets.car holds every appearance (light, dark, tinted, clear); Petal.icns is the fallback.
cp "$ROOT/brand/macos/Assets.car" "$ROOT/brand/macos/Petal.icns" "$APP/Contents/Resources/"
cp "$ROOT/defaults/modes-macos.json" "$APP/Contents/Resources/modes.json"

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
</dict>
</plist>
PLIST

codesign --force --options runtime --sign "$IDENTITY" "$APP" 2>/dev/null
echo "built $APP $VERSION ($( [ "$IDENTITY" = "-" ] && echo "ad hoc" || echo "signed"))"
