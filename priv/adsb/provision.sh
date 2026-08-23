#!/bin/bash
# Rebuild the Air Defense ADS-B receiver from a blank Raspberry Pi OS Lite install.
#
# Deliberately self-contained: one file to scp across and run. The alternative — a
# directory of fragments, or an SD-card image — is exactly what you do not want at
# 11pm with a dead card. An image would also restore an unpatched OS.
#
# Prerequisites (Raspberry Pi Imager, before first boot):
#   hostname `adsb`, your user, SSH **public-key only**, locale America/New_York,
#   Wi-Fi OFF (use ethernet for the first boot so a Wi-Fi typo cannot strand you).
#
# Usage:   sudo LAT=<lat> LON=<lon> WIFI_SSID=<ssid> bash provision.sh
#          sudo ... UUID_FILE=~/airplanes-uuid bash provision.sh   # keep feeder identity
#
# Idempotent: safe to re-run. Prompts for secrets; never stores them in this file.
#
# LAT/LON/WIFI_SSID have no defaults on purpose. This repo is public, and a receiver
# position accurate enough for MLAT (5+ decimals, ~1 m) is a home address. Keep yours
# in your shell history or a local env file, not in version control.

set -uo pipefail

LAT=${LAT:-}
LON=${LON:-}
ALT=${ALT:-}
WIFI_SSID=${WIFI_SSID:-}
ADMIN_USER=${ADMIN_USER:-${SUDO_USER:-}}
UUID_FILE=${UUID_FILE:-}
DB_URL=https://github.com/wiedehopf/tar1090-db/raw/csv/aircraft.csv.gz

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -n "$LAT" ] && [ -n "$LON" ] || { echo "set LAT= and LON= (decimal degrees) — see the header"; exit 1; }
[ -n "$WIFI_SSID" ] || { echo "set WIFI_SSID= to the network the receiver joins"; exit 1; }
id "$ADMIN_USER" >/dev/null 2>&1 || { echo "no such user: '$ADMIN_USER' (set ADMIN_USER=)"; exit 1; }

step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
ok()   { printf '    ok  %s\n' "$*"; }
warn() { printf '    !!  %s\n' "$*"; }

step "Preflight"
lsusb | grep -qi 'RTL2838\|RTL2832' && ok "SDR dongle present" || warn "no RTL-SDR seen on USB — readsb will start but decode nothing"
curl -s -m 10 -o /dev/null https://github.com && ok "internet reachable" || { warn "no internet — aborting"; exit 1; }
timedatectl show -p Timezone --value | grep -q . && ok "timezone $(timedatectl show -p Timezone --value)"

step "Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && ok "apt lists updated" || warn "apt update failed"
apt-get install -y -qq jq curl unattended-upgrades >/dev/null 2>&1 && ok "jq curl unattended-upgrades"

step "readsb decoder (wiedehopf)"
if command -v readsb >/dev/null; then ok "already installed"
else
  bash -c "$(wget -nv -O - https://github.com/wiedehopf/adsb-scripts/raw/master/readsb-install.sh)" </dev/null \
    && ok "installed" || { warn "readsb install FAILED — aborting"; exit 1; }
fi

step "tar1090 web UI + JSON endpoint"
# NOTE: tar1090 serves the JSON at /tar1090/data/aircraft.json — NOT /data/aircraft.json.
# Air Defense's local_feed_url must include the /tar1090 prefix.
if [ -d /usr/local/share/tar1090 ]; then ok "already installed"
else
  bash -c "$(wget -nv -O - https://github.com/wiedehopf/tar1090/raw/master/install.sh)" </dev/null \
    && ok "installed" || warn "tar1090 install failed"
fi

step "Aircraft database (type + registration)"
# readsb omits the `t` and `r` fields entirely without --db-file, so the recent-flights
# list shows blank aircraft types. tar1090's own git-db is browser-side only.
mkdir -p /usr/local/share/tar1090-db
if wget -q -O /usr/local/share/tar1090-db/aircraft.csv.gz "$DB_URL" && gzip -t /usr/local/share/tar1090-db/aircraft.csv.gz; then
  ok "aircraft.csv.gz ($(du -h /usr/local/share/tar1090-db/aircraft.csv.gz | cut -f1))"
  grep -q 'db-file' /etc/default/readsb || \
    sed -i 's|^JSON_OPTIONS="\(.*\)"|JSON_OPTIONS="\1 --db-file=/usr/local/share/tar1090-db/aircraft.csv.gz"|' /etc/default/readsb
  ok "wired into JSON_OPTIONS"
else warn "database download failed — type/registration will be blank"; fi

step "Receiver location"
readsb-set-location "$LAT" "$LON" >/dev/null 2>&1 && ok "$LAT, $LON"
systemctl restart readsb && ok "readsb restarted"

step "Log access without sudo"
# /var/log/lighttpd is root-only, and that access log is the only independent proof that
# Air Defense is really polling. A chgrp does NOT survive: lighttpd's unit resets the
# directory on start. Group MEMBERSHIP does survive, so join the group instead.
usermod -aG www-data "$ADMIN_USER" && ok "$ADMIN_USER added to www-data"

step "SSH hardening"
printf 'PermitRootLogin no\n' > /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t && systemctl reload ssh && ok "root login disabled (password auth is already off via Imager)"

step "Unattended security upgrades"
cat > /etc/apt/apt.conf.d/52air-defense-unattended <<'CONF'
// Headless, Wi-Fi-only, isolated VLAN, no wired fallback.
//
// The "Raspberry Pi Foundation" origin (kernel + firmware) is deliberately NOT listed.
// A bad kernel or firmware update here means physically retrieving the Pi. Apply those
// by hand: sudo apt update && sudo apt full-upgrade
//
// NOTE: APT config lists are ADDITIVE — this file appends to the stock
// 50unattended-upgrades rather than replacing it. Check the union with:
//   apt-config dump | grep Origins-Pattern
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-updates";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
// Reboot even with a login session open, else one forgotten ssh session blocks every
// reboot forever on a machine nobody logs into.
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
CONF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
# Patch at 01:00 so a required reboot lands in the 02:00 window the SAME night. The
# stock 06:00 schedule patches at 6am then idles ~20h waiting for the reboot time.
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 01:00\nRandomizedDelaySec=20m\n' \
  > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
systemctl daemon-reload; systemctl restart apt-daily-upgrade.timer
systemctl enable unattended-upgrades.service >/dev/null 2>&1
ok "Debian security at 01:00, reboot 02:00; Pi kernel/firmware stay manual"

step "Health monitor (Pushover)"
cat > /usr/local/bin/adsb-health <<'HEALTH'
#!/bin/bash
# Pushover health monitor for the Air Defense ADS-B receiver.
#
# Every failure mode of this box is silent: a dead SDR still looks like a running
# service, and a dying SD card just remounts read-only. Alerts fire on state CHANGE
# only, which is what keeps the channel worth reading.
#
# Deliberately NOT alerted: temperature (the 3B+ soft-throttles above 60C by design),
# Wi-Fi signal, routine Debian patching — noise that trains you to ignore alerts.
set -uo pipefail
CONF=/etc/adsb-health.conf
STATE=/var/lib/adsb-health
[ -r "$CONF" ] || { echo "missing $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
mkdir -p "$STATE"

notify() {
  curl -s -m 20 --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
       --form-string "title=$1" --form-string "message=$2" --form-string "priority=${3:-0}" \
       https://api.pushover.net/1/messages.json >/dev/null
}
edge() {
  local key=$1 now=$2 was
  was=$(cat "$STATE/$key" 2>/dev/null || echo ok)
  printf '%s' "$now" > "$STATE/$key"
  [ "$now" = "$was" ] && return
  if [ "$now" = bad ]; then notify "$3" "$4" "${5:-0}"
  else notify "RESOLVED: $3" "Back to normal." 0; fi
}

case "${1:-}" in
  --test) notify "ADS-B receiver" "Test from $(hostname) at $(date '+%H:%M %Z'). Monitoring is live." 0; echo sent; exit 0 ;;
  --boot) notify "ADS-B receiver rebooted" "$(hostname) came back up at $(date '+%H:%M %Z') on kernel $(uname -r); readsb $(systemctl is-active readsb)." -1; exit 0 ;;
esac

## SD card dying — the filesystem drops to read-only.
if awk '$2=="/"{print $4}' /proc/mounts | cut -d, -f1 | grep -qx ro; then
  edge rootfs bad "ADS-B: filesystem READ-ONLY" "The SD card has likely failed. Flight data is stale. Reimage needed." 1
else edge rootfs ok "ADS-B: filesystem READ-ONLY"; fi

## Under-voltage (bit 0 now, bit 16 since boot). NOT the temperature bits (3/19), which
## are benign on a 3B+ and would cry wolf. Under-voltage is what corrupts cards.
TH=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
if [ -n "$TH" ] && (( (TH & 0x1) || (TH & 0x10000) )); then
  edge volt bad "ADS-B: UNDER-VOLTAGE" "throttled=$TH — inadequate PSU or cable. This corrupts SD cards. Replace the supply." 1
else edge volt ok "ADS-B: UNDER-VOLTAGE"; fi

## Receiver deaf. readsb can be 'active' while hearing nothing (dongle dropped off USB,
## antenna knocked loose). The message COUNTER is the honest signal — NYC airspace is
## never silent, so a frozen counter means the SDR is dead, and unlike an aircraft count
## it does not false-alarm at 3am.
MSG=$(curl -s -m 8 http://localhost/tar1090/data/aircraft.json 2>/dev/null | jq -r '.messages // empty')
PREV=$(cat "$STATE/messages" 2>/dev/null || echo "")
[ -n "$MSG" ] && printf '%s' "$MSG" > "$STATE/messages"
if [ -z "$MSG" ]; then
  edge deaf bad "ADS-B: decoder unreachable" "readsb/tar1090 not answering on localhost. Service state: $(systemctl is-active readsb)." 1
elif [ -n "$PREV" ] && [ "$MSG" = "$PREV" ]; then
  edge deaf bad "ADS-B: receiver is DEAF" "readsb is running but decoded 0 new messages since the last check. Check the SDR dongle and antenna." 1
else edge deaf ok "ADS-B: receiver is DEAF"; fi

## Automatic patching silently stopped.
if systemctl is-failed --quiet unattended-upgrades.service || systemctl is-failed --quiet apt-daily-upgrade.service; then
  edge uu bad "ADS-B: auto-updates FAILED" "unattended-upgrades or apt-daily-upgrade is in a failed state. Security patches are not being applied." 0
else edge uu ok "ADS-B: auto-updates FAILED"; fi

## Disk.
USE=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "${USE:-0}" -ge 85 ]; then
  edge disk bad "ADS-B: disk ${USE}% full" "Root filesystem at ${USE}%. $(df -h / | awk 'NR==2{print $4}') free." 0
else edge disk ok "ADS-B: disk full"; fi

## Raspberry Pi kernel/firmware pending — excluded from unattended upgrades on purpose,
## so they accumulate and need a human. Weekly digest.
STAMP=$STATE/rpi-digest
if [ ! -f "$STAMP" ] || [ "$(( ($(date +%s) - $(stat -c %Y "$STAMP")) / 86400 ))" -ge 7 ]; then
  # Never contend with apt: blocking here wedges the oneshot, and with it the timer,
  # because OnUnitActiveSec= only re-arms once the unit deactivates.
  if ! pgrep -x 'apt|apt-get|dpkg|unattended-upgrade' >/dev/null; then
    # apt-get -s prints the ORIGIN on each Inst line, so one simulation replaces a
    # per-package apt-cache loop (~100 subprocesses, minutes of wall clock on a 3B+).
    SIM=$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst .*Raspberry Pi Foundation')
    N=$(printf '%s' "$SIM" | grep -c .)
    if [ "${N:-0}" -gt 0 ]; then
      KERNEL=$(printf '%s\n' "$SIM" | awk '/^Inst linux-image-rpi/{print $2; exit}')
      notify "ADS-B: $N Pi updates pending" \
        "Kernel/firmware updates need a manual run (excluded from auto-updates on purpose).${KERNEL:+ Includes $KERNEL.} Run: sudo apt update && sudo apt full-upgrade" 0
    fi
    touch "$STAMP"
  fi
fi
HEALTH
chmod 755 /usr/local/bin/adsb-health

printf '[Unit]\nDescription=Air Defense receiver health check (Pushover)\nAfter=network-online.target\n[Service]\nType=oneshot\nTimeoutStartSec=180\nExecStart=/usr/local/bin/adsb-health\n' \
  > /etc/systemd/system/adsb-health.service
printf '[Unit]\nDescription=Run the ADS-B receiver health check every 15 minutes\n[Timer]\nOnBootSec=5min\nOnUnitActiveSec=15min\nAccuracySec=1min\n[Install]\nWantedBy=timers.target\n' \
  > /etc/systemd/system/adsb-health.timer
printf '[Unit]\nDescription=Notify that the ADS-B receiver rebooted\nAfter=network-online.target readsb.service\nWants=network-online.target\n[Service]\nType=oneshot\nExecStartPre=/bin/sleep 20\nExecStart=/usr/local/bin/adsb-health --boot\n[Install]\nWantedBy=multi-user.target\n' \
  > /etc/systemd/system/adsb-health-boot.service

if [ -r /etc/adsb-health.conf ]; then ok "credentials already present, keeping them"
else
  echo "    Pushover credentials (hidden input, stored 0600 root-only; blank to skip):"
  read -rsp "      App/API token: " T; echo
  read -rsp "      User key     : " U; echo
  if [ -n "$T" ] && [ -n "$U" ]; then
    install -m 600 -o root -g root /dev/null /etc/adsb-health.conf
    printf 'PUSHOVER_TOKEN=%s\nPUSHOVER_USER=%s\n' "$T" "$U" > /etc/adsb-health.conf
    ok "wrote /etc/adsb-health.conf"
  else warn "skipped — monitor installed but inert until /etc/adsb-health.conf exists"; fi
fi
systemctl daemon-reload
systemctl enable --now adsb-health.timer >/dev/null 2>&1 && ok "timer armed (15 min)"
systemctl enable adsb-health-boot.service >/dev/null 2>&1 && ok "boot notification enabled"
[ -r /etc/adsb-health.conf ] && /usr/local/bin/adsb-health --test >/dev/null && ok "test notification sent"

step "Wi-Fi ($WIFI_SSID)"
# Ethernet stays up; nothing here can strand you mid-run. Two settings matter and both
# are non-obvious: a randomized MAC defeats the DHCP reservation, and power save costs
# ~80ms of latency and jitter on every poll.
if nmcli -g NAME connection show | grep -qx "$WIFI_SSID"; then ok "profile exists"
else
  nmcli connection add type wifi con-name "$WIFI_SSID" ifname wlan0 ssid "$WIFI_SSID" \
    -- wifi-sec.key-mgmt wpa-psk >/dev/null && ok "profile created"
fi
nmcli connection modify "$WIFI_SSID" \
  wifi.cloned-mac-address permanent \
  wifi.powersave 2 \
  ipv4.dhcp-client-id none \
  ipv4.dhcp-hostname "$(hostname)" \
  ipv4.method auto \
  connection.autoconnect yes connection.autoconnect-priority 10 && ok "MAC pinned, power save off, no DHCP client-id"
nmcli radio wifi on
echo "    wlan0 MAC (the DHCP reservation key — NOT eth0's): $(cat /sys/class/net/wlan0/address)"
echo "    connect with:  sudo nmcli --ask connection up $WIFI_SSID"

step "airplanes.live feeder"
if [ -n "$UUID_FILE" ] && [ -f "$UUID_FILE" ]; then
  mkdir -p /usr/local/share/airplanes
  install -m 644 -o root -g root "$UUID_FILE" /usr/local/share/airplanes/airplanes-uuid
  ok "restored feeder identity from $UUID_FILE (run their installer AFTER this)"
else
  warn "no UUID_FILE given — their installer will mint a NEW feeder identity"
fi
echo "    Their installer is an interactive whiptail TUI (public MLAT name, antenna"
echo "    position to 5 decimals, altitude with a unit suffix, e.g. 38m). Run it by hand:"
echo "      sudo bash -c \"\$(wget -qO - https://raw.githubusercontent.com/airplanes-live/feed/main/install.sh)\""

step "Result"
systemctl is-active readsb lighttpd tar1090 adsb-health.timer 2>/dev/null | paste -sd' ' -
sleep 5
curl -s -m 8 http://localhost/tar1090/data/aircraft.json | jq -c '{aircraft: ([.aircraft[]|select(.lat)]|length), messages}' 2>/dev/null
cat <<EOM

Point Air Defense at:  http://$(hostname).internal/tar1090/data/aircraft.json
  (tar1090 serves under /tar1090/ — a bare /data/aircraft.json 404s)

Remaining, by hand:
  1. sudo nmcli --ask connection up $WIFI_SSID     then unplug ethernet once verified
  2. DHCP reservation on the wlan0 MAC above, plus a DNS override for $(hostname).internal
  3. airplanes.live feeder installer (see above)
EOM
