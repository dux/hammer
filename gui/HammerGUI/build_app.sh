#!/usr/bin/env bash
# Build the release binary and assemble ../Hammer.app (the bundle the gem
# vendors and `hammer --gui` launches). Re-run after changing any Swift
# source. arm64-only; targets macOS 11+.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"   # gui/HammerGUI
GUI_DIR="$(dirname "$HERE")"            # gui
APP="$GUI_DIR/Hammer.app"
NAME="HammerGUI"

cd "$HERE"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hammer</string>
  <key>CFBundleDisplayName</key><string>Hammer</string>
  <key>CFBundleIdentifier</key><string>com.lux-hammer.gui</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "built $APP"
