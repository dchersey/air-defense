#!/bin/bash
# Back up the IRREPLACEABLE state of the Air Defense receiver setup.
#
# Deliberately NOT an SD-card image. An image is ~32 GB of mostly-stock Raspberry Pi OS,
# it is stale the moment it is taken, and restoring it reinstates an unpatched system.
# Almost everything on that Pi is reproducible from packages and install scripts. What is
# NOT reproducible is a handful of small text files, and they total under 20 KB.
#
# Usage:  ./backup-receiver.sh [destination-dir]      (default: ~/Dropbox/air-defense-backups)
#
# Default lands in Dropbox so the archive survives losing the Mac itself. That is also
# why live credentials are deliberately kept OUT of it (see RESTORE.md) — this file
# syncs to a third party, so anything in it should be recoverable-but-not-secret.

set -uo pipefail
HOST=${ADSB_HOST:-adsb}
DEST=${1:-$HOME/Dropbox/air-defense-backups}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$DEST/air-defense-$STAMP"
MACCFG="$HOME/Library/Application Support/air-defense"
mkdir -p "$WORK/pi" "$WORK/mac" || exit 1

say() { printf '  %-52s %s\n' "$1" "$2"; }

# ---- Pi: the one genuinely unrecreatable file, plus config worth diffing later --------
# airplanes-uuid IS the feeder identity. Lose it and you are a brand new feeder with no
# history. Everything else here is cheap to re-derive but saves reconstruction time.
for f in /usr/local/share/airplanes/airplanes-uuid \
         /etc/default/airplanes \
         /etc/default/readsb \
         /etc/apt/apt.conf.d/52air-defense-unattended \
         /etc/apt/apt.conf.d/20auto-upgrades \
         /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf \
         /etc/systemd/system/adsb-health.service \
         /etc/systemd/system/adsb-health.timer \
         /etc/systemd/system/adsb-health-boot.service \
         /usr/local/bin/adsb-health \
         /etc/ssh/sshd_config.d/99-hardening.conf \
         /etc/lighttpd/lighttpd.conf; do
  out="$WORK/pi/$(echo "${f#/}" | tr / _)"
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "cat '$f'" > "$out" 2>/dev/null && [ -s "$out" ]; then
    say "$f" "ok"
  else
    rm -f "$out"; say "$f" "SKIPPED (missing or needs root)"
  fi
done
ssh -o BatchMode=yes "$HOST" 'uname -a; echo; dpkg -l | awk "/readsb|tar1090|unattended|firmware-brcm/{print \$2, \$3}"' \
  > "$WORK/pi/_system-inventory.txt" 2>/dev/null && say "system inventory" "ok"

# ---- Mac: the zone geometry. Weeks of hand tuning, and it lives outside git. ----------
for f in config.json credits.json aeroapi.json; do
  if [ -f "$MACCFG/$f" ]; then cp "$MACCFG/$f" "$WORK/mac/$f"; say "Air Defense $f" "ok"
  else say "Air Defense $f" "absent"; fi
done

cat > "$WORK/RESTORE.md" <<'NOTE'
# Restoring the Air Defense receiver

Most of this system is reproducible; only a few things here are not.

## Irreplaceable
- `pi/usr_local_share_airplanes_airplanes-uuid` — the airplanes.live **feeder identity**.
  Restore to `/usr/local/share/airplanes/airplanes-uuid` (root:root 0644) BEFORE
  re-running their installer, or you become a new feeder and lose your history.
- `mac/config.json` — the hand-tuned zonesets. Restore to
  `~/Library/Application Support/air-defense/config.json`, then restart the backend.

## Secrets NOT in this archive (recover from source, do not store here)
- Pushover token/user  -> Pushover dashboard, rewrite `/etc/adsb-health.conf` (0600 root)
- Wi-Fi PSK            -> `sudo nmcli --ask device wifi connect <SSID> ifname wlan0`
- AeroAPI key          -> FlightAware account, paste in Settings (stored in Keychain)

## Rebuilding the Pi from a blank card
1. Pi OS Lite 64-bit via Imager: hostname `adsb`, your user, SSH public-key only,
   locale America/New_York. Wi-Fi off; use ethernet for the first boot.
2. readsb + tar1090:
     sudo bash -c "$(wget -nv -O - https://github.com/wiedehopf/adsb-scripts/raw/master/readsb-install.sh)"
     sudo bash -c "$(wget -nv -O - https://github.com/wiedehopf/tar1090/raw/master/install.sh)"
3. Aircraft type/registration (readsb omits `t`/`r` without it):
     sudo wget -O /usr/local/share/tar1090-db/aircraft.csv.gz \
       https://github.com/wiedehopf/tar1090-db/raw/csv/aircraft.csv.gz
   then append `--db-file=/usr/local/share/tar1090-db/aircraft.csv.gz` to JSON_OPTIONS
   in /etc/default/readsb  (or just restore the copy in pi/).
4. Restore the files in `pi/` to their original paths, `systemctl daemon-reload`.
5. Wi-Fi: pin `wifi.cloned-mac-address permanent` and `ipv4.dhcp-client-id none`, or the
   DHCP reservation will not match. Also `wifi.powersave 2` — power save costs ~80 ms of
   latency and jitter. wlan0 MAC is the reservation key, NOT eth0's.
6. Air Defense points at `http://adsb.internal/tar1090/data/aircraft.json`
   (tar1090 serves under /tar1090/, NOT /).
NOTE

# Finder drops .DS_Store into any directory it touches; keep it out of the archive.
tar --exclude '.DS_Store' -czf "$WORK.tar.gz" -C "$DEST" "air-defense-$STAMP" && rm -rf "$WORK"
echo
echo "  -> $WORK.tar.gz  ($(du -h "$WORK.tar.gz" | cut -f1))"
ls -1t "$DEST"/air-defense-*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f   # keep 10
