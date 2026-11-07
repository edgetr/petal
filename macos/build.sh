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
cp "$ROOT/defaults/modes-macos.json" "$APP/Contents/Resources/modes.json"
cp "$ROOT/plugin/assets/claude.svg" "$ROOT/plugin/assets/openai.svg" "$APP/Contents/Resources/"
# Which names anyone can register under (co.uk, github.io): the vault fills a login only on its own site (VaultSite).
cp "$ROOT/macos/Resources/public_suffix_list.dat" "$APP/Contents/Resources/"
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
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Petal Dock</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>tech.edgetr.petal.recipe</string></array>
      <key>CFBundleTypeIconSystemGenerated</key><true/>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>tech.edgetr.petal.recipe</string>
      <key>UTTypeDescription</key><string>Petal Dock</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>petal</string></array>
        <key>public.mime-type</key><array><string>application/x-petal</string></array>
      </dict>
    </dict>
  </array>
  <key>NSAppleEventsUsageDescription</key><string>Petal reads which site a browser tab is on, to keep distracting ones in their mode, and closes one when you choose Stay. It also shows what's playing in Music and Spotify, and opens and empties the Trash in Finder.</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --entitlements Petal.entitlements --sign "$IDENTITY" "$APP" 2>/dev/null
codesign --verify --strict "$APP"
echo "built $APP $VERSION ($( [ "$IDENTITY" = "-" ] && echo "signed ad hoc" || echo "signed by $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"))"
