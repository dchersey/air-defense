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

# Code-sign with a stable identity so macOS keeps the Accessibility grant across
# rebuilds (unsigned/ad-hoc rebuilds silently lose TCC trust — see SIGN_IDENTITY).
# Override the identity via SIGN_IDENTITY env; empty string skips signing.
SIGN_IDENTITY="${SIGN_IDENTITY-Apple Development: David Hersey (CUACYBN73G)}"
if [ -n "$SIGN_IDENTITY" ]; then
  if codesign --force --deep --sign "$SIGN_IDENTITY" "$app" 2>/dev/null; then
    echo "Signed with: $SIGN_IDENTITY"
  else
    echo "WARN: codesign failed for identity '$SIGN_IDENTITY' — app is unsigned (Accessibility grant won't persist)."
  fi
fi

echo "Built $app"

# Install to /Applications unless --here was passed.
if [ "${1:-}" != "--here" ]; then
  dest="/Applications/LGA Overflight.app"
  killall LgaPredictor 2>/dev/null || true
  rm -rf "$dest"
  cp -R "$app" "$dest"
  echo "Installed → $dest  (launch from Launchpad/Spotlight: \"LGA Overflight\")"
  echo "NOTE: re-grant Accessibility to this copy on first launch (TCC is per-path)."
  echo "Open now:  open -a \"LGA Overflight\""
else
  echo "Run:  open \"$app\""
fi
echo
echo "First launch: grant Accessibility to LgaPredictor.app in"
echo "  System Settings → Privacy & Security → Accessibility"
echo "and pin Sound to the menu bar (System Settings → Control Center → Sound → Always Show)."
