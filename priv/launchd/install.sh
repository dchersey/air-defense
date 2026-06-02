#!/bin/bash
# Install/reinstall the air-defense headless service as a per-user LaunchAgent.
# Boots idle at login; the menu-bar app drives sessions. FR24 key comes from
# Keychain, so no secret is written anywhere here.
#
#   ./priv/launchd/install.sh            # install + load
#   ./priv/launchd/install.sh uninstall  # unload + remove
set -euo pipefail

LABEL="org.hersey.air-defense"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"

if [ "${1:-}" = "uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled $LABEL"
  exit 0
fi

ELIXIR="$(command -v elixir)"
if [ -z "$ELIXIR" ]; then echo "ERROR: elixir not found on PATH"; exit 1; fi

# Give the agent a PATH that includes the elixir/erlang bin dir (for `erl`).
AGENT_PATH="$(dirname "$ELIXIR"):/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

sed -e "s|@REPO@|$REPO|g" \
    -e "s|@ELIXIR@|$ELIXIR|g" \
    -e "s|@PATH@|$AGENT_PATH|g" \
    -e "s|@HOME@|$HOME|g" \
    "$REPO/priv/launchd/$LABEL.plist.template" > "$PLIST"

echo "Wrote $PLIST"

# Fetch deps + compile once so the agent doesn't fail on first boot.
( cd "$REPO" && MIX_ENV=prod mix deps.get >/dev/null && MIX_ENV=prod mix compile >/dev/null ) \
  && echo "Compiled (prod)." || { echo "ERROR: prod compile failed"; exit 1; }

# Reload cleanly.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Loaded $LABEL. Check: curl -s 127.0.0.1:4040/api/status ; log: ~/Library/Logs/air-defense.log"
