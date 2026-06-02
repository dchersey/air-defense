# Cold-install smoke test

Run on a **second Mac or a fresh macOS user account** (Apple Silicon, macOS 15+) so
you exercise the real "never built this" path — no Elixir, no Xcode, no keychain
entry, no prior permission grants. The make-or-break items for a release are
**§1** (the curl path), **§3** (notarization on a machine that never trusted the
cert), and **§5** (the Accessibility-driven ANC switch on a fresh TCC grant) —
those can't be verified on an already-trusted dev machine.

## 0. Environment
- [ ] Apple Silicon, macOS 15+, **no** developer toolchain installed
- [ ] An FR24 Explorer API key handy to paste

## 1. Run the installer
```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/air-defense/main/install.sh)"
```
- [ ] "Downloading the backend release…" succeeds (no 404)
- [ ] Prompts for the FR24 key; pasting it reports **"Stored in Keychain"**
- [ ] "Service loaded" → "Downloading the menu-bar app…" → "Installed → /Applications/Air Defense.app"
- [ ] App launches automatically; **Air Defense** appears in the menu bar (no Dock icon)

## 2. Verify the install landed (Terminal)
```sh
launchctl print "gui/$(id -u)/org.hersey.air-defense" >/dev/null && echo "agent loaded"
security find-generic-password -s air-defense-fr24 -w >/dev/null && echo "key in keychain"
ls -d "$HOME/Library/Application Support/air-defense/backend/bin/air_defense" && echo "release present"
curl -s 127.0.0.1:4040/api/status | python3 -m json.tool | head
```
- [ ] agent loaded · key in keychain · release present
- [ ] `/api/status` returns JSON (`active:false`, `credits_budget_month`, empty `zonesets`)
- [ ] `~/Library/Logs/air-defense.log` shows a clean boot, no crash loop

## 3. Gatekeeper / notarization (the point of signing)
```sh
spctl --assess --type execute --verbose=4 "/Applications/Air Defense.app"   # → accepted, source=Notarized Developer ID
codesign --verify --strict --verbose=2 "/Applications/Air Defense.app"        # → valid on disk / satisfies Designated Requirement
xcrun stapler validate "/Applications/Air Defense.app"                        # → The validate action worked!
```
- [ ] App opened with **no "unidentified developer" / quarantine warning**
- [ ] All three commands pass

## 4. Grant the two manual permissions
- [ ] System Settings → Privacy & Security → **Accessibility** → enable **Air Defense**
- [ ] System Settings → Control Center → **Sound** → *Always Show in Menu Bar*
- [ ] Menu-bar panel shows status (not "offline") — app ↔ backend talking

## 5. ANC actuator works (no live plane needed)
With AirPods Max connected and set as output, in Transparency:
```sh
curl -s -X POST 127.0.0.1:4040/api/actuator/cover \
  -H 'Content-Type: application/json' -d '{"on_ms":0,"off_ms":10000,"label":"smoke"}'
```
- [ ] AirPods flip to **ANC**, then back to **Transparency** ~10 s later
- [ ] Control Center popover closes itself; keyboard focus returns to your app
- [ ] Menu-bar icon goes red (engaged) → back to default

## 6. End-to-end detection (needs traffic, or a drawn zone)
- [ ] Add a zoneset (paste GeoJSON / "Open in geojson.io") — saves and lists
- [ ] **Start** that zone; when a qualifying flight enters the monitor box, the icon
      goes amber (inbound) → red (engaged), and `air-defense.log` shows one `TRIGGER`
      then a polling gap (lock-on) until it clears
- [ ] **Stop** ends the session; goes idle

## 7. Credit bar
- [ ] Bar shows "N left" / budget with the day-of-cycle hashmark
- [ ] **Sync** → enter reset day + a remaining number → bar updates; `credits.json` written

## 8. Optional companion
- [ ] With [Keep Sound Alive](https://github.com/dchersey/keep-sound-alive) running, starting a
      session pushes a hold (AirPods stay connected); stopping pops it
- [ ] With it **not** running, everything above still works (no errors in the log)

## 9. Uninstall (leave the test machine clean)
```sh
launchctl bootout "gui/$(id -u)/org.hersey.air-defense"
rm -f "$HOME/Library/LaunchAgents/org.hersey.air-defense.plist"
rm -rf "$HOME/Library/Application Support/air-defense" "/Applications/Air Defense.app"
security delete-generic-password -s air-defense-fr24
```
- [ ] All gone; `/api/status` no longer responds
