#!/bin/bash
# Build TermHub.app — a proper macOS application bundle.
# Usage: ./scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/TermHub"
APP="$ROOT/build/TermHub.app"

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TermHub"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon (optional — generate with ./scripts/make-icon.sh).
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "   (no Resources/AppIcon.icns yet — app will use the default icon)"
fi

# Ad-hoc sign so notifications / TCC treat it as a stable identity.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "   (codesign skipped — not fatal for local runs)"

echo "==> Done: $APP"
echo "    Launch with: open \"$APP\""
