#!/bin/bash
# Convert a square PNG (ideally 1024x1024) into Resources/AppIcon.icns.
# Usage: ./scripts/make-icon.sh path/to/icon.png
set -euo pipefail

SRC="${1:-}"
if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Usage: $0 path/to/icon.png (square, ideally 1024x1024)"
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# macOS expects these sizes (points @1x and @2x).
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    px="${spec%% *}"
    name="${spec##* }"
    sips -z "$px" "$px" "$SRC" --out "$ICONSET/icon_${name}.png" >/dev/null
done

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> Wrote Resources/AppIcon.icns"
echo "    Now rebuild the app: ./scripts/make-app.sh release"
