#!/bin/bash
# Builds dist/Wave Bar.app: a menu bar app without a Dock icon.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/Wave Bar.app"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/WaveBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WaveBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Wave Bar</string>
  <key>CFBundleDisplayName</key><string>Wave Bar</string>
  <key>CFBundleIdentifier</key><string>io.github.wavebar</string>
  <key>CFBundleExecutable</key><string>WaveBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built: $APP"
