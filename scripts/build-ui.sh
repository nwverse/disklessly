#!/usr/bin/env bash
# Copy the management page and, on a Mac with Pake installed, wrap it as 256isenough.app.
# CI and Linux set ISENOUGH_SKIP_PAKE=1 or simply lack the pake binary; asset copy still runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ISENOUGH_UI_DEST:-$ROOT/.build/ui}"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$ROOT/Sources/isenough/web/index.html" "$ROOT/Sources/isenough/web/app.js" "$ROOT/Sources/isenough/web/style.css" "$DEST/"
test -s "$DEST/index.html"
test -s "$DEST/app.js"
test -s "$DEST/style.css"
echo "web assets: $DEST"
if [[ "${ISENOUGH_SKIP_PAKE:-}" == "1" ]] || ! command -v pake >/dev/null 2>&1; then
  echo "pake packaging skipped (install pake and leave ISENOUGH_SKIP_PAKE unset to build 256isenough.app)"
  exit 0
fi
URL="${ISENOUGH_UI_URL:-http://127.0.0.1:47256/}"
pake "$URL" --name 256isenough --show-system-tray
echo "Pake wrapper: 256isenough.app (loads $URL; start it with isenough ui and pass that printed URL)"
