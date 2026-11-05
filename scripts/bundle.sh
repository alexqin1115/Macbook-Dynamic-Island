#!/bin/bash
# Builds a release binary and wraps it in an ad-hoc signed NotchIsland.app under dist/.
set -euo pipefail
# BUNDLE_ID: override the bundle identifier (changing it makes macOS ask for privacy permissions again).
# ADHOC=1: always sign ad-hoc (use for release builds so no developer identity is embedded).
BUNDLE_ID="${BUNDLE_ID:-com.macbookdynamicisland.NotchIsland}"
VERSION="${VERSION:-0.1.2}"
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release
APP=dist/NotchIsland.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/NotchIsland" "$APP/Contents/MacOS/NotchIsland"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>__BUNDLE_ID__</string>
  <key>CFBundleName</key><string>NotchIsland</string>
  <key>CFBundleExecutable</key><string>NotchIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>__BUNDLE_ID__</string><key>CFBundleURLSchemes</key><array><string>notchisland</string></array></dict></array>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Shows a notice in the notch when a Bluetooth device such as AirPods connects.</string>
  <key>NSAppleEventsUsageDescription</key><string>Lets the notch control playback in Apple Music and Spotify and read the current track.</string>
</dict>
</plist>
PLIST
sed -i '' -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"
# A stable identity keeps privacy grants (Full Disk Access) across rebuilds; ad-hoc signing resets them every time.
IDENTITY=""
if [ -z "${ADHOC:-}" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
