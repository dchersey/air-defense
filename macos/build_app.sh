#!/bin/bash
# Build the SwiftUI menu-bar control panel into a no-Dock-icon agent .app bundle.
# Usage:  ./macos/build_app.sh   then:  open ./macos/LgaPredictor.app
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/ControlPanel"

echo "Building (release)…"
swift build -c release

app="$here/LgaPredictor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/release/ControlPanel" "$app/Contents/MacOS/LgaPredictor"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LgaPredictor</string>
  <key>CFBundleDisplayName</key><string>LGA Overflight</string>
  <key>CFBundleIdentifier</key><string>org.hersey.lgapredictor.panel</string>
  <key>CFBundleExecutable</key><string>LgaPredictor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "Built $app"
echo "Run:  open \"$app\""
echo "Rebuild+relaunch:  killall LgaPredictor 2>/dev/null; ./macos/build_app.sh; open \"$app\""
echo
echo "First launch: grant Accessibility to LgaPredictor.app in"
echo "  System Settings → Privacy & Security → Accessibility"
echo "and pin Sound to the menu bar (System Settings → Control Center → Sound → Always Show)."
