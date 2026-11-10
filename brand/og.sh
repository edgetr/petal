#!/bin/bash
# Draws brand/og.html into site/og.png (1200×630), the picture a shared link to petal.codes shows.
# It needs a headless Chromium: Playwright's chrome-headless-shell, or any other with CHROME_HEADLESS=<path>.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
chrome="${CHROME_HEADLESS:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-*/chrome-headless-shell 2>/dev/null | tail -1)}"
[ -x "$chrome" ] || { echo "No headless Chromium found. Set CHROME_HEADLESS to one." >&2; exit 1; }
profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT
"$chrome" --headless --disable-gpu --hide-scrollbars --user-data-dir="$profile" --allow-file-access-from-files \
  --window-size=1200,630 --virtual-time-budget=3000 --screenshot="$here/../site/og.png" "file://$here/og.html" 2>/dev/null
echo "site/og.png written"
