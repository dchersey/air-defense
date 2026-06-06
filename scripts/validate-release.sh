#!/bin/bash
# Validate a published Air Defense release end-to-end — NON-DESTRUCTIVELY.
#
#   scripts/validate-release.sh            # validate the latest release
#   scripts/validate-release.sh v0.5.0     # validate a specific tag
#
# It only downloads the release assets into a temp dir and inspects them. It NEVER
# touches your LaunchAgent, /Applications, the Accessibility grant, or a running
# dev build — so it's safe to run while you're using the app from source.
#
# Checks, exactly what a fresh `curl … install.sh` depends on:
#   1. the installer's asset URLs actually download;
#   2. the self-contained backend release boots under its own bundled ERTS (no
#      system Elixir/Erlang) and reports the packaged version — without binding the
#      API port (LGA_NO_SERVER=1), so it can't collide with a running instance;
#   3. the app is Developer ID-signed, notarized, stapled, and Gatekeeper-accepted.
#
# Exit 0 = clean, 1 = a check failed, 2 = wrong platform. Used in CI (release.yml)
# against the just-published assets, and runnable locally any time.
set -uo pipefail

REPO="dchersey/air-defense"
TAG="${1:-}"
fail=0
say() { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$1"; }
bad() { printf "  \033[1;31m✗\033[0m %s\n" "$1"; fail=1; }

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only (the release is an arm64 macOS app)."; exit 2; }

# Resolve the download base. With an explicit tag we hit that release directly (no
# gh/auth needed); otherwise use /latest and best-effort label it via gh.
if [ -n "$TAG" ]; then
  BASE="https://github.com/$REPO/releases/download/$TAG"
else
  BASE="https://github.com/$REPO/releases/latest/download"
  TAG="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || echo latest)"
fi
say "Validating release: $TAG"

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

# 1. Downloads (the exact URLs install.sh uses) ------------------------------
say "Downloading release assets…"
curl -fsSL "$BASE/air-defense-backend-macos-arm64.tar.gz" -o "$t/backend.tgz" \
  && ok "backend.tgz ($(stat -f%z "$t/backend.tgz") bytes)" || bad "backend download failed"
curl -fsSL "$BASE/AirDefense.zip" -o "$t/app.zip" \
  && ok "AirDefense.zip ($(stat -f%z "$t/app.zip") bytes)" || bad "app download failed"

# 2. Backend: self-contained runtime boots ----------------------------------
say "Backend release…"
mkdir -p "$t/backend" "$t/home"
tar -xzf "$t/backend.tgz" -C "$t/backend" 2>/dev/null || bad "backend tar failed to extract"
if [ -x "$t/backend/bin/air_defense" ]; then
  ok "bin/air_defense present + executable"
  vsn="$(HOME="$t/home" LGA_NO_SERVER=1 RELEASE_DISTRIBUTION=none \
        "$t/backend/bin/air_defense" eval \
        'IO.puts(Application.spec(:lga_predictor, :vsn))' 2>/dev/null | tail -1)"
  [ -n "$vsn" ] && ok "bundled runtime boots — packaged version $vsn" \
                || bad "bundled runtime failed to boot"
else
  bad "bin/air_defense missing or not executable"
fi

# 3. App: signature / notarization / Gatekeeper ------------------------------
say "App bundle…"
ditto -x -k "$t/app.zip" "$t/appout" 2>/dev/null || bad "AirDefense.zip failed to unzip"
app="$(/usr/bin/find "$t/appout" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "$app" ]; then
  bad "no .app bundle inside AirDefense.zip"
else
  codesign --verify --deep --strict "$app" 2>/dev/null \
    && ok "code signature valid" || bad "codesign --verify failed"
  auth="$(codesign -dvvv "$app" 2>&1 | grep -m1 'Authority=Developer ID Application' | sed 's/.*Authority=//')"
  [ -n "$auth" ] && ok "signed by: $auth" || bad "not a Developer ID Application signature"
  spctl --assess --type execute "$app" 2>/dev/null \
    && ok "Gatekeeper: accepted" || bad "Gatekeeper rejected the app"
  xcrun stapler validate "$app" >/dev/null 2>&1 \
    && ok "notarization ticket stapled" || bad "no stapled notarization ticket"
fi

echo
if [ "$fail" = 0 ]; then
  printf "\033[1;32m✅ %s validated — the download installs cleanly.\033[0m\n" "$TAG"
else
  printf "\033[1;31m❌ %s FAILED validation (see ✗ above).\033[0m\n" "$TAG"
fi
exit "$fail"
