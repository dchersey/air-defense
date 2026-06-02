#!/bin/bash
# Air Defense — one-shot installer for the backend service (+ the menu-bar app).
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/air-defense/main/install.sh)"
#
# Downloads a self-contained Elixir release (no Elixir/Erlang/Xcode needed),
# installs it as a per-user LaunchAgent, stores your FlightRadar24 key in the
# Keychain, and installs the notarized menu-bar app. Apple Silicon, macOS 15+.
set -euo pipefail

REPO="dchersey/air-defense"
LABEL="org.hersey.air-defense"
SUPPORT="$HOME/Library/Application Support/air-defense"
BACKEND="$SUPPORT/backend"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/air-defense.log"
BASE="https://github.com/$REPO/releases/latest/download"

say() { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only."
if [ "$(uname -m)" != "arm64" ]; then
  die "Prebuilt release is Apple Silicon (arm64) only. On Intel, build from source — see the README."
fi

# 1. Backend release ---------------------------------------------------------
say "Downloading the backend release…"
mkdir -p "$BACKEND" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$BASE/air-defense-backend-macos-arm64.tar.gz" -o "$tmp/backend.tgz" \
  || die "Couldn't download the backend release. Is there a published release yet?"
rm -rf "$BACKEND"/*            # clean any prior release (config.json lives one level up, untouched)
tar -xzf "$tmp/backend.tgz" -C "$BACKEND"
[ -x "$BACKEND/bin/air_defense" ] || die "Release looks wrong — bin/air_defense missing."

# 2. FlightRadar24 key (Keychain) -------------------------------------------
if security find-generic-password -s air-defense-fr24 -w >/dev/null 2>&1; then
  say "FlightRadar24 key already in your Keychain — keeping it."
else
  echo
  echo "Air Defense needs a FlightRadar24 API key (the Explorer plan is enough)."
  echo "Get one at https://fr24api.flightradar24.com/ — it's stored only in your Keychain."
  printf "Paste your FR24 API key (leave blank to skip for now): "
  read -r FR24_KEY </dev/tty || FR24_KEY=""
  if [ -n "$FR24_KEY" ]; then
    security add-generic-password -a "$USER" -s air-defense-fr24 -U -w "$FR24_KEY"
    say "Stored in Keychain (service: air-defense-fr24)."
  else
    say "Skipped — add it later: security add-generic-password -a \"\$USER\" -s air-defense-fr24 -U -w '<key>'"
  fi
fi

# 3. LaunchAgent -------------------------------------------------------------
say "Installing the LaunchAgent…"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BACKEND/bin/air_defense</string>
    <string>start</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>RELEASE_DISTRIBUTION</key><string>none</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
say "Service loaded (logs: $LOG). API on http://127.0.0.1:4040."

# 4. Menu-bar app ------------------------------------------------------------
say "Downloading the menu-bar app…"
if curl -fsSL "$BASE/AirDefense.zip" -o "$tmp/app.zip"; then
  ditto -x -k "$tmp/app.zip" "$tmp/app"
  appsrc="$(/usr/bin/find "$tmp/app" -maxdepth 1 -name '*.app' | head -1)"
  if [ -n "$appsrc" ]; then
    rm -rf "/Applications/Air Defense.app"
    ditto "$appsrc" "/Applications/Air Defense.app"
    open "/Applications/Air Defense.app" || true
    say "Installed → /Applications/Air Defense.app"
  fi
else
  say "App download skipped (no published app yet) — grab it from https://github.com/$REPO/releases/latest"
fi

cat <<'DONE'

✅ Done. Two one-time manual steps macOS requires:
   1) Grant Accessibility:  System Settings → Privacy & Security → Accessibility → enable "Air Defense"
      (it drives Control Center to toggle ANC).
   2) Pin Sound to the menu bar:  System Settings → Control Center → Sound → "Always Show in Menu Bar".

Then click the Air Defense menu-bar icon and Start a zone. Optional: install
"Keep Sound Alive" (https://github.com/dchersey/keep-sound-alive) so AirPods
don't idle-disconnect mid-session — Air Defense uses it automatically if present.
DONE
