#!/bin/bash
# Renders Resources/icon.svg into Resources/AppIcon.icns. Needs Google Chrome for the SVG render.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$TMP/icon.png" "file://$PWD/Resources/icon.svg" 2>/dev/null

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$TMP/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Built: Resources/AppIcon.icns"
