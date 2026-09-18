# Air Defense

[![CI](https://github.com/dchersey/air-defense/actions/workflows/ci.yml/badge.svg)](https://github.com/dchersey/air-defense/actions/workflows/ci.yml)
[![License: Source Available](https://img.shields.io/badge/license-Source%20Available%20(MIT%20%2B%20Commons%20Clause)-blue.svg)](LICENSE)

https://github.com/user-attachments/assets/0748e274-c487-4781-aa19-3b3a418021ef

A macOS menu-bar app that watches the sky and automatically switches your AirPods
Max into **Active Noise Cancellation** the moment an aircraft is about to pass over
you — then back to your previous listening mode once it's gone. A little SAM site for airplane
noise: detect the inbound, lock on, engage.

## The problem

I live close to a major airport — LaGuardia — that recently expanded its
schedule. Some days the departures and arrivals funnel right over my apartment in
Queens, and the noise was driving me up the wall. I like the windows open. I don't
like a 737 in the living room.

AirPods Max ANC is genuinely magic for this — flip to Noise Cancellation and the
plane basically disappears. But wearing them in full ANC *all day* means being
sealed off from everything else (the kettle, the buzzer, my own apartment), and
manually toggling the mode every 90 seconds as planes come and go is absurd.

What I actually wanted: stay in **Transparency** — open, aware, normal — and have
something flip me to **ANC only for the ~30 seconds a plane is overhead**, hands
free. So I built an air-defense system for it. It watches live flight traffic,
predicts which planes will actually cross over me and when, and engages ANC just in
time, every time.

## Current scope and data sources

**The airplanes.live API has been suspended and is disabled in Air Defense.** It is
no longer offered in Settings, and requests through that provider are rejected.
Existing configurations using airplanes.live (or the previously retired adsb.lol)
migrate to **Local receiver**, preserving the configured receiver URL and zones.
Set that URL to a working receiver before expecting traffic. There is no supported
free public position API in this app; **FlightRadar24 is the optional paid alternative**.

Most development now focuses on my **local ADS-B receiver** and the traffic around
my apartment in Queens under LaGuardia's flight paths. The local features—including
low/high/river approach classification, background activity, route history, and
noise timing—are designed and calibrated for this location. Those route names
and classification thresholds describe what I hear here; they are not a general
airport-routing model.

**I do not plan to build a setup or adaptation workflow for other locations.**
The zone editor and configuration are available to experiment with, but changing
coordinates alone does not make the local features portable. Contributions that
adapt them for other locations, or make them more general, are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## What it does

- **Tracks local traffic** from a readsb/dump1090 receiver. No position API key or
  per-request charge; you supply the receiver hardware and network connection.
- **Engages ANC for overhead aircraft** and restores the listening mode you had
  before the overflight.
- **Uses monitor and ANC zones** to detect inbound aircraft and decide when they
  are close enough to matter. The receiver returns its full picture; the app
  filters it locally.
- **Tracks activity outside ANC sessions**, classifies my local arrival routes,
  and records seven-day route timelines and rolling 30-day route shares.
- **Pauses ANC monitoring when the AirPods are no longer the active output** and
  resumes when they return. Background local-receiver observations continue.
- **Supports FlightRadar24** as a paid position source, with credit accounting.
  Background traffic and route classification are disabled on that metered feed.
- **Stays out of the way.** No Dock icon—amber for inbound traffic, red while
  ANC is engaged, and quiet otherwise.

It's two pieces: a headless **Elixir/OTP** service that tracks traffic and exposes a
localhost-only JSON API, and a **SwiftUI menu-bar app** that provides the control
panel and switches ANC. Switching normally uses a private CoreBluetooth path,
with Control Center Accessibility automation as a fallback.

## How it works

A **zoneset** pairs a monitor zone upstream with one or more **ANC zones** where
traffic is loud over the listener. Tracking queries cover the union of those
zones so an aircraft remains visible between detection and the overhead pass.
Timing offsets can be set globally or per zone.

- **Arrivals:** the tracked-arrival mode uses ETA to increase polling frequency as
  a flight approaches, then engages on observed zone entry. Release is predicted
  from closest approach to the listener plus an acoustic-decay allowance, or from
  the zone dwell when listener geometry is unavailable. Predicting the release is
  important here: the antenna often loses aircraft after they pass the building.
- **Departures:** climbing and banking aircraft are tracked through the zone.
  Successive observations keep ANC engaged while the aircraft is overhead; it
  releases when those holds expire after exit or loss of tracking.

Both show amber while inbound and red while ANC is engaged. The arrival banner
has a clear-by countdown; live-tracked departures show a radar mark.

[`config.example.json`](config.example.json) contains my two zone geometries as an
example, with the local receiver selected. Configure its URL under **Settings →
Data source → Local receiver**. Receiver setup and diagnostics are documented in
[`priv/adsb/README.md`](priv/adsb/README.md). These examples document my setup;
there is no supported location-adaptation wizard.

ANC sessions are manual: **Start** a zone when needed; it runs for about four hours
or until stopped. With the local receiver configured, background activity and route
classification continue outside those sessions.

## Switching the AirPods mode

Air Defense sets noise control **silently** — no windows, no focus stealing, no keyboard
interruption. It asks `bluetoothd` (which owns the AAP link to your AirPods) through the
same private CoreBluetooth path Control Center itself uses, so the switch is a direct IPC
call rather than UI automation. It can also *read* the true current mode, which is how it
restores exactly what you had after an overflight.

The sequence, for anyone maintaining this (`Sources/ADBluetooth/ADListeningMode.m`):

1. Satisfy CoreBluetooth's TCC handshake — a real `CBCentralManager` with a delegate,
   awaited to `poweredOn`. Until that completes, bluetoothd parks the client at
   `fAccessLevel 0` and withholds everything.
2. Create a `CBClassicManager` on its own serial queue; these objects are queue-affine
   and calls from another thread silently do nothing.
3. **The gate:** `-[CBClassicManager retrievePairedPeersWithOptions:]` begins with
   `if (![self tccApproved]) return nil;` — it returns nil *without sending any XPC*,
   which makes it look like the API is dead. `performTCCCheck` doesn't reliably flip the
   flag even though bluetoothd has already approved the session, so set it directly.
4. `retrievePairedPeersWithOptions:` → `CBClassicPeer` objects → `setListeningMode:`
   (`1`=Off `2`=ANC `3`=Transparency `4`=Adaptive), which becomes AACP control command
   `0x0D` on the wire.

It's private API, so it's treated as a runtime capability, never an assumption: if any
step fails the app falls back to **automating the Control Center Sound popover via
Accessibility**, which does briefly grab the keyboard (that's the "sub-second blip" older
versions had on every switch). Keep the Accessibility grant and the pinned Sound menu
item for that fallback — and note **Reclaim always uses it**, since a pair the phone has
taken exposes no CoreBluetooth peer to talk to.

Routes that do *not* work on macOS 26, all verified rather than assumed: the **Shortcuts**
"Set Noise Control Mode" action (silent no-op); **`IOBluetoothDevice.setListeningMode:`**
(writes a local ivar — reads back correctly and never reaches the hardware); the
**CoreAudio HAL** (listening mode isn't a device property); and speaking **AAP over
L2CAP** directly (macOS refuses third-party L2CAP channels on every PSM, signed or not —
bluetoothd owns that link, which is why you ask it instead of bypassing it).

## Reclaiming AirPods after a phone call

On **macOS 27**, Apple moved the Sound and Control Center menu items into
`com.apple.MenuBarAgent`, under a dialog rather than an `AXMenuBar`. The opened
panels still belong to Control Center. Air Defense searches the new host first
and retains the older Control Center lookup for earlier macOS versions. This
change does not itself require regranting Accessibility permission.

When an iPhone answers a call it takes the AirPods, and macOS often doesn't hand them
back when the call ends — the usual fix is taking the headphones off and putting them
back on. Air Defense notices (monitoring pauses, "AirPods not connected") and offers a
**Reclaim** button right in that banner to pull them back to the Mac.

It opens **Control Center**, expands the **Sound** tile, and presses the AirPods row —
so it carries the same sub-second keyboard blip described above. It deliberately does
*not* go through the Sound menu-bar item that mode switching uses: that item only exists
while Sound is pinned "Always Show" or is active, so on the default "Show When Active"
it vanishes the moment the AirPods leave — exactly when a reclaim is needed. Control
Center is always present.

The obvious cleaner routes don't work, and they fail in ways that *look* like success:

- **CoreAudio** can't select them: while the phone owns the audio profile the AirPods
  disappear from the Mac's device list entirely, so there is nothing to make default.
- **IOBluetooth** can't either: `isConnected()` still reports `true` (the baseband link
  stays with the Mac, decoupled from who owns the audio) and `openConnection()` returns
  success in ~0 s without moving any audio.

That also makes CoreAudio presence — not the Bluetooth connection state — the only
reliable signal for "the phone has them".

The same thing happens **automatically when you start a session**, so beginning a watch
while your AirPods are still on your phone doesn't just drop you straight into the paused
state. Nothing is grabbed if they're already on the Mac, if they're sitting in their case,
or if two live pairs make the choice ambiguous — in that last case use the button, which
prefers whichever pair you used here last.

Detection falls out of the same list: Control Center shows exactly the AirPods that are
**powered on and reachable**, so a pair in its case is simply absent, and `v=1` marks
whichever is already selected. Bluetooth state is no substitute — `isConnected()` reads
`true` for a pair the phone is holding, and can go stale besides.

Two wrinkles if you touch this code, both about `sound-device-<name>` being shared by
*everything* belonging to a device:

- An `AXDisclosureTriangle` carries it too; pressing that opens the listening-mode
  submenu instead of switching output. Require `AXCheckBox`.
- Once a device is selected its submenu renders inline, adding a checkbox per listening
  mode plus Spatial Audio and Conversation Awareness — all under that same identifier,
  several reading as checked. Identifier alone would misreport "already connected" and
  could press *Adaptive* instead of the device. Only the device row's **description**
  starts with the device name (`AirPods Max, 84%`); submenu rows read `Adaptive`, `Off`,
  and so on.

## Install

**Apple Silicon, macOS 15+.** One command sets up the backend and installs the
menu-bar app:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/air-defense/main/install.sh)"
```

It downloads a **self-contained** backend release (no Elixir/Erlang/Xcode needed),
installs it as a per-user LaunchAgent, and installs the app to `/Applications`.
**A local ADS-B receiver is required for the default data source.** Configure its
URL in Settings; no position API key is needed for that receiver. Alternatively,
select FlightRadar24 and enter a paid API key. Installation does not provide a
receiver or a free public feed.

The downloadable binaries are **code-signed with my Apple Developer ID and notarized
by Apple** (and stapled), so Gatekeeper opens them without the "unidentified
developer" warning — every release is built, signed, and notarized in CI.

Two one-time steps macOS requires and the script can't do for you:

1. **Grant Accessibility** — System Settings → Privacy & Security → Accessibility →
   enable **Air Defense**. (Required for the Control Center fallback and Reclaim.)
2. **Pin Sound to the menu bar** — System Settings → Control Center → Sound →
   *Always Show in Menu Bar*.

Set the receiver URL in **Settings → Data source**, then **Start** a zone.

## Keep Sound Alive (optional companion)

If you wear AirPods Max for ANC with **nothing playing**, Bluetooth will quietly
idle-disconnect them after a couple of minutes — and your air defense goes down
with it. [**Keep Sound Alive**](https://github.com/dchersey/keep-sound-alive) is a
tiny companion app that plays an inaudible tone to keep the connection alive. If
it's installed, Air Defense automatically tells it to hold the connection during a
session and release it afterward.

It's entirely optional — **Air Defense works fine without it** (the calls are
best-effort and fail quietly if it isn't running).

## Build from source

Intel Macs (the prebuilt release is arm64-only) and contributors build from source.
Requires Elixir ~> 1.19 / OTP 29 and a recent Swift toolchain (macOS 15+):

```sh
git clone https://github.com/dchersey/air-defense.git
cd air-defense

# Backend (headless service)
mix deps.get
./priv/launchd/install.sh        # runs the service from source as a LaunchAgent
#   or, for a foreground dev run:  iex -S mix   (API on http://127.0.0.1:4040)

# Menu-bar app
./macos/build_app.sh             # builds, signs with your local identity, installs
```

`mix test` runs the suite. Developed on macOS 26 ("Tahoe"); the Control Center
automation targets that layout and may need small tweaks on other versions.

### Cutting & validating a release

Push a `v*` tag (e.g. `git tag v0.5.0 && git push origin v0.5.0`) — `release.yml`
builds the self-contained backend, signs the app with the Developer ID, notarizes
and staples it, and publishes the GitHub Release. A follow-up `validate` job then
re-downloads the just-published assets and confirms a fresh install would be clean.

That same check is a script you can run any time — it's **non-destructive** (temp
dir only; it never touches your LaunchAgent, `/Applications`, the Accessibility
grant, or a running dev build):

```sh
scripts/validate-release.sh            # the latest release
scripts/validate-release.sh v0.5.0     # a specific tag
```

It verifies the installer's download URLs resolve, the backend release boots under
its own bundled ERTS (no system Elixir/Erlang) without binding the API port, and the
app is Developer ID-signed, notarized, stapled, and accepted by Gatekeeper.

## Using it

**Route history** opens a seven-column lookback: today and the preceding six local
calendar days, with time of day running down each column. Amber marks low approaches,
blue/teal high approaches, and green river approaches. Hover a block for its route and
time range. The bottom bar shows each route's percentage of **classified time over the
last 30 days**, with recorded hours and coverage alongside it; these are not percentages
of aircraft. Classification reports the noisiest route in meaningful use, so this is a
history of the inferred airport routing, not a census of individual flights.

History records in the background from the local receiver, even without an ANC session,
and survives app/backend restarts. It requires the airport and home coordinates used
by the existing route classifier. Classification is specific to my apartment and
LaGuardia; the chart records those local classifications. Blank time is unclassified or unobserved, including
outages and time before this feature was installed. Previous route changes cannot be
reconstructed from the old single-route state file. Data is retained for 30 days in
`~/Library/Application Support/air-defense/route-history.json`. The view refreshes once
a minute; observations are recorded on the classifier's 30-second cadence. Day columns
use local wall time (the repeated autumn DST hour shares rows, and the missing spring
hour stays blank); duration percentages use actual elapsed time.

- **Data source** picker: `Local receiver` (default) or `FlightRadar24` (paid).
  Set the receiver URL, or paste an FR24 key (stored in the macOS Keychain).
  Applies to all zones. airplanes.live is disabled because its API is suspended.
- **Start / Stop** per zone from the menu — each zone runs its own session.
- **Edit zones** inline: paste GeoJSON, or "Open in geojson.io" to draw a box over
  the map and bring it back. Set a per-zone poll interval.
- **ANC timing offset** sliders nudge the computed engage/release moments ±15 s.
- When the provider is **FR24**, a **credit bar** shows what's left against your
  monthly allotment, with a hashmark at the day-of-cycle. Hit **Sync** to enter the
  *remaining* balance from your FR24 dashboard and your billing **reset day**.
- **Flight routes** (optional): paste a **FlightAware AeroAPI** key to label the
  recent-flights list and the inbound banner with `ORIG → DEST`; without one it shows
  the raw callsign. This is just a display label — separate from the position feed.

## Provider notes

**Default: local receiver.** Air Defense reads `aircraft.json` from a local
readsb/dump1090 receiver, typically at
`http://adsb.local/tar1090/data/aircraft.json`. Adjust the hostname to your setup.
This is the source used for background activity, route classification, and route
history. See the [receiver guide](priv/adsb/README.md) for provisioning and diagnostics.

**Disabled: airplanes.live.** Its public API has been suspended. Air Defense no
longer selects or calls that provider. Older configurations migrate to Local receiver;
users without a receiver can explicitly choose the paid FR24 alternative.

**Optional paid source: FlightRadar24.** Obtain an API key from
[FlightRadar24's API portal](https://fr24api.flightradar24.com/) and paste it in
Settings. The key is stored in the macOS Keychain (service `air-defense-fr24`,
`FR24_API_KEY` environment fallback), never in the repository or launchd plist.
The `light` position feed is billed per flight returned, so small query areas matter.

If a local receiver repeatedly fails and an FR24 key is stored, the current app can
fall back to FR24 temporarily. The panel identifies the active provider and the
reason for the switch. During fallback, it probes the local receiver every 30 seconds
and switches back after a successful response, without restarting monitoring or
resetting session timers. Failed probes leave fallback in place; these local checks
spend no credits and continue while monitoring is paused or idle. Starting another
session also rechecks the receiver. This fallback
spends FR24 credits; background classification and activity collection pause while it
is in use.

> The credit bar is a **self-tally**: Air Defense counts every credit it spends and you
> periodically Sync it to the dashboard number. It rolls over on your billing
> anniversary (the reset day you set).

**Flight routes (optional — separate from the position feed):** the ADS-B and FR24
feeds give positions and callsigns, not where a flight is *going*. To label the
recent-flights list and the inbound banner with **`ORIG → DEST`** instead of a bare
callsign, Air Defense can resolve callsigns through
**[FlightAware AeroAPI](https://www.flightaware.com/commercial/aeroapi/)** — real-time
and delay-aware, unlike the static scheduled-route databases that were quietly wrong
for regional callsigns reused across the day. This is **purely a display label; it
plays no part in detecting or tracking aircraft** (that's all ADS-B). Paste an AeroAPI
key into the app's **Flight routes** setting — stored only in your macOS Keychain
(service `air-defense-aeroapi`, `AEROAPI_KEY` env fallback), never committed. Lookups
are cached one-per-callsign (a route is fixed once a flight is airborne), run in the
background so they never block a poll, and are capped to **1,000/month**. This is a
billed API; consult your FlightAware plan for current pricing and allowances.
With no key, over the cap, or on a miss,
the list falls back to the raw callsign. Route labels are separate from the local
low/high/river approach classifier and its history chart.

## Layout

```
lib/lga_predictor/      Elixir service: geo, predictor, fr24 client, poller,
                        config_store, route_history, credit_ledger, actuator, api/router
macos/ControlPanel/     SwiftUI menu-bar app (control panel + ANC actuator)
macos/build_app.sh      Builds the app + installs to /Applications
config.example.json     My two real zonesets (one arrival, one departure) as a sample
install.sh              End-user curl installer (backend release + app)
priv/launchd/           Dev LaunchAgent (runs the service from source)
scripts/                FR24 probes, the historic backtest, validate-release.sh
test/                   ExUnit tests (TDD)
```

## Limitations

- **Apple Silicon, macOS 15+.** Intel: build from source.
- Local features are tuned for *my* apartment under *LaGuardia's* paths. I do not
  plan to develop location-adaptation tooling; contributions are welcome. The
  zone editor alone does not adapt route classification or acoustic assumptions.
- It can only switch a device that's currently your active output and connected;
  pair it with Keep Sound Alive so the AirPods don't nap mid-session.
- The normal ANC switch uses private CoreBluetooth APIs and may depend on macOS
  behavior. Its Control Center fallback needs Accessibility and Sound pinned to
  the menu bar.
- airplanes.live is disabled. Use a local receiver or paid FR24 positions.

## Why this license?

Air Defense is free to use, modify, and share for any **noncommercial** purpose —
personal use, hobby projects, tinkering, learning, and contributions back are all
welcome and always will be. The one thing the license doesn't permit is **selling**
the software (or charging for hosting/support whose value comes mainly from it).

I built this to solve my own problem and I'm happy to share it freely; I just don't
want it repackaged and sold out from under the people it's meant to help. If you
have a commercial use in mind, get in touch and we can sort something out.

## License

Source-available under the **MIT License with the Commons Clause** — free to use, modify, and redistribute for any **noncommercial** purpose; you may not sell the software. See [LICENSE](LICENSE).
