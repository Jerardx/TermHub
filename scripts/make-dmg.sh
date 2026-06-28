#!/bin/bash
# Build a distributable TermHub.dmg from build/TermHub.app.
# Run ./scripts/make-app.sh release first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/TermHub.app"
DMG="$ROOT/build/TermHub.dmg"
VOL="TermHub"

if [[ ! -d "$APP" ]]; then
    echo "Missing $APP — run ./scripts/make-app.sh release first."
    exit 1
fi

STAGE="$(mktemp -d)"
echo "==> Staging…"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Building DMG…"
rm -f "$DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> Done: $DMG"
echo "    Open it, then drag TermHub into Applications."
