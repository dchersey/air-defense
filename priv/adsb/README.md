# Self-hosted ADS-B receiver

Air Defense's `local` provider reads flight data straight from a receiver you own: free,
~4 ms away, and dependent on no third party. This directory holds everything needed to
build one, keep it alive, and diagnose it.

| | |
|---|---|
| `provision.sh` | Rebuild a receiver from a blank Raspberry Pi OS Lite card |
| `backup-receiver.sh` | Archive the few files that are genuinely unrecreatable |
| `adsb-dbsample` | Sample signal levels to a CSV — the diagnostic tool |

## Quick start

Flash **Raspberry Pi OS Lite (64-bit)** with Imager: set a hostname, your user, **SSH
public-key only**, your timezone. Leave **Wi-Fi off** and use ethernet for the first boot,
so a mistyped passphrase cannot strand a headless box. Then:

```sh
scp provision.sh <host>:
ssh -t <host> 'sudo LAT=<lat> LON=<lon> WIFI_SSID=<ssid> bash provision.sh'
```

It installs readsb + tar1090, the aircraft database, unattended security upgrades, and a
Pushover health monitor; it prompts for secrets and stores none of them in the repo.
Point Air Defense at the URL it prints, under **Settings → Data source → Local receiver**.

`provision.sh` is deliberately self-contained — one file to copy across when a card has
died. It is not an SD-card image on purpose: an image is ~32 GB of reproducible OS, it is
stale the moment you take it, and restoring one reinstates an unpatched system.

## Things that are not obvious

Each of these cost real time to discover. They are the actual value of this directory.

**tar1090 serves the JSON under `/tar1090/`.** The URL is
`http://<host>/tar1090/data/aircraft.json`. A bare `/data/aircraft.json` returns 404.

**Aircraft type and registration need a separate database.** readsb omits the `t` and `r`
fields entirely unless given `--db-file`; tar1090's own database is browser-side only. Without
it the recent-flights list shows blank aircraft types. `provision.sh` wires this up.

**A Pi's Wi-Fi and Ethernet MACs are different.** A DHCP reservation built on the ethernet
MAC will never match once the receiver moves to Wi-Fi — no error, just a lease that drifts
and a receiver that disappears after a power cut. Use `cat /sys/class/net/wlan0/address`.

**Pin the MAC and suppress the DHCP client-id**, or the reservation still may not stick:

```sh
nmcli connection modify <ssid> wifi.cloned-mac-address permanent ipv4.dhcp-client-id none
```

NetworkManager can randomise MACs, and a client that sends a client-identifier is matched
on *that* rather than on hardware address by most DHCP servers.

**Disable Wi-Fi power save.** It is on by default and it is brutal: measured across the
same link, latency went from **87 ms average / 82 ms jitter → 4.4 ms / 0.6 ms**.

```sh
nmcli connection modify <ssid> wifi.powersave 2
```

**Pin the gain. Do not trust autogain.** See below — this is the one most likely to bite.

**Expect aircraft to vanish once they pass the antenna**, if anything blocks that side.
This is geometry, not a fault, and Air Defense is built for it: the poller schedules the
ANC release at *engage* time rather than waiting to observe the aircraft leave. Do not
"fix" the disappearing aircraft by making release wait on an observed exit.

## Gain: the trap a good antenna sets

A well-sited antenna can make the receiver **deaf to the closest aircraft** — the exact
population that matters most, and the failure is silent. readsb still reports `active`,
message counts look healthy, and maximum range looks better than ever.

Mode-S messages that clip the ADC fail CRC and are discarded, so only the *weaker* samples
survive into the average. The tell is a signal that **falls as an aircraft gets closer**:

```
              gain 48 (autogain)        after pinning gain
0.70 nm            -1.5 dBFS                   -11.3
0.31 nm            -5.4  ← 4 dB WEAKER          -6.2  ← stronger, as physics requires
ADC saturating     43% of samples               0%
```

Halving the range should add ~6 dB. Losing 4 dB instead is ~10 dB of clipping.

Autogain will not necessarily rescue you: on one receiver it oscillated between the top
two tuner steps for 17 hours and never came down. Fix it manually — the value depends on
your siting, so measure rather than copy this number:

```sh
sudo readsb-gain 33.8      # hot-applies via /run/readsb/setGain, no restart
```

Verify by watching a close pass: **signal should rise monotonically all the way in.** Cutting
~14 dB of gain cost no sensitivity at all in testing — the weakest aircraft still decoded at
−49.5 dBFS either way. Re-check after any antenna move, because *improving* the antenna is
what causes this.

## Measuring

`adsb-dbsample <minutes> <interval_seconds>` writes a CSV of RSSI spread, ADC peak, closest
aircraft, and temperature. Needs no root.

```sh
./adsb-dbsample 60 60     # quiet-sky baseline
./adsb-dbsample 30 1      # a close pass — a jet crosses overhead in seconds
```

Three ways to fool yourself with this data, all learned the hard way:

- **`peak_signal` is a trailing-minute maximum.** Samples within 60 s of a gain change still
  contain pre-change data. Wait a minute before believing it.
- **`max_range` from one snapshot measures traffic, not sensitivity.** It is just the
  farthest aircraft that happened to be airborne. Compare over time, or not at all.
- **Per-aircraft `rssi` is a rolling mean and hides clipping.** Use the ADC peak for that.

And when scripting against the receiver over ssh: never `pkill -f` a pattern that also
appears in the command you are running — it matches your own session and kills it.

## Antenna

At 1090 MHz a quarter wave is only **6.9 cm**, so nothing needs to be large.

- **Mount it vertically.** ADS-B is vertically polarised; horizontal costs ~20 dB.
- **A half-wave (13.8 cm) is the forgiving choice** if the base is plastic: a quarter-wave
  monopole needs a ground plane to work against, a half-wave does not.
- **Line of sight beats everything.** Moving a receiver from an interior spot to a window
  facing the approach path nearly doubled its range (35 → 63 nm) — worth more than any
  antenna upgrade.
- **Put the dongle at the antenna and run USB, not coax.** Thin coax loses roughly 1 dB per
  metre at 1 GHz; USB loses nothing.

## Monitoring and backup

`provision.sh` installs a Pushover monitor (15-minute timer, alerts only on state *change*)
watching: filesystem gone read-only, under-voltage, **readsb's message counter frozen**,
failed auto-updates, disk above 85%, and a weekly digest of pending Pi kernel/firmware
updates.

The frozen-counter check is the valuable one. readsb reports `active` while hearing nothing
at all if the dongle drops off USB — and unlike an aircraft count, a message counter does
not false-alarm at 3am.

Deliberately **not** alerted: temperature (a Pi 3B+ soft-throttles above 60 °C by design),
Wi-Fi signal, and routine patching — noise that trains you to ignore the channel.

`backup-receiver.sh` archives ~12 KB: the airplanes.live feeder UUID (lose it and you are a
new feeder with no history) and Air Defense's hand-tuned zone geometry, which lives outside
this repo. Live credentials are excluded on purpose — all are recoverable from their source
in a minute, and the archive is meant to sit in cloud storage.

## Security posture

The receiver is treated as an untrusted appliance: its own isolated VLAN, reachable *from*
the main network but unable to initiate connections back to it. Air Defense only ever makes
HTTP GETs, so this pull-only arrangement costs nothing.

Note that inter-VLAN traffic routed through a firewall arrives at an access point bearing
the *gateway's* MAC, which is why **client isolation does not block it** — and why the
receiver's access log shows the gateway as the client rather than the polling machine.
