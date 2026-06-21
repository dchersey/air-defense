# Air Defense

[![CI](https://github.com/dchersey/air-defense/actions/workflows/ci.yml/badge.svg)](https://github.com/dchersey/air-defense/actions/workflows/ci.yml)
[![License: Source Available](https://img.shields.io/badge/license-Source%20Available%20(MIT%20%2B%20Commons%20Clause)-blue.svg)](LICENSE)

https://github.com/user-attachments/assets/0748e274-c487-4781-aa19-3b3a418021ef

A macOS menu-bar app that watches the sky and automatically switches your AirPods
Max into **Active Noise Cancellation** the moment an aircraft is about to pass over
you — then back to **Transparency** once it's gone. A little SAM site for airplane
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

## What it does

- **Tracks live traffic** via a **free ADS-B feed** (airplanes.live) —
  no API key, no cost — and predicts, per flight, *when* it will be overhead:
  distance to the noisy zone ÷ ground speed. (FlightRadar24 is an optional
  alternative provider if you prefer it.)
- **Engages ANC just before** the plane arrives and **releases it** once the plane
  clears — so you're only cancelling when it actually matters.
- **Only watches small boxes.** You draw a tiny **monitor zone** upstream; that's
  the only thing polled — cheap on the free feed, and credit-frugal on FR24.
- **Locks on.** Once it's caught an inbound it stops polling that zone until the
  plane clears.
- **Pauses when you take the AirPods off** (or switch output away) and resumes when
  they're back, so it never toggles a device that isn't listening.
- **Tracks FR24 credits** (when you use FR24) against your monthly allotment with a
  pace bar, so you can see whether you're burning them faster than the month.
- **Stays out of the way.** No Dock icon — a menu-bar icon that's amber when a plane
  is inbound, red while ANC is engaged, and quiet otherwise.

It's two pieces: a headless **Elixir/OTP** service that does the prediction and
exposes a localhost-only JSON API, and a **SwiftUI menu-bar app** that's the
control panel and performs the actual ANC switch (by driving Control Center through
the macOS Accessibility API — every no-UI route is dead on current macOS).

## How it works

You define **zonesets**. A zoneset is:

- a **monitor zone** — a small box upstream where planes are first detected (the
  only thing polled), and
- one or more **ANC zones** — where it's actually loud over you (never polled).

When a flight shows up in a monitor zone, Air Defense computes its straight-line
distance to the ANC zone and divides by ground speed to get a time-to-overhead,
then schedules ANC to **engage** on predicted entry and **release** on predicted
exit. Two global sliders (±15 s) nudge the on/off moments to taste, and a
configurable `anc_latency_seconds` fires each switch slightly early so the mode has
actually changed by the time the plane arrives.

### Two kinds of zone: arrivals (steady) vs departures (accelerating)

Each zoneset has a **type** — set it with the Arrival / Departure picker in the zone
editor — because the two flight phases behave differently:

- **Arrival (steady).** On final approach a jet is already on a stable vector:
  roughly constant heading and speed. "Distance ÷ ground speed" is a good predictor,
  so an arrival zone **schedules** the engage/release from that ETA, exactly as
  above, and shows a **clear-by countdown** while the plane is overhead.

- **Departure (accelerating).** Climbing out, a jet is still **accelerating and
  banking**, and it turns at a different point on different days — some climb
  straight, some make a big turn, some pass you entirely. A far-out ETA mistimes the
  engage, and a near-distance threshold false-triggers on the ones that miss. So a
  departure zone doesn't predict — it **tracks**: it polls fast (the free feed is
  unmetered) over the **union** of the monitor and ANC zones to keep the climbing
  plane on radar through the gap, **engages on actual entry** (latency-adjusted so
  the mode flips just as it crosses in), **holds** ANC while it's overhead, and
  **releases on the actual exit** rather than a straight-line dwell that would
  under-count a curving path. A plane that's merely near the zone but tracking away
  (a miss) never engages and is dropped once it's past. While it's live-tracked the
  banner shows a **radar mark** instead of a countdown.

Both types drive the same menu-bar signals: **amber** when a plane is inbound and
closing, **red** while ANC is engaged.

See [`config.example.json`](config.example.json) for my two actual zones — one of
each type — as a worked example you can adapt (copy it to
`~/Library/Application Support/air-defense/config.json`, or just read it alongside
the zone editor).

Sessions are manual: hit **Start** on a zone when the planes start, and it runs for
~4 hours or until you stop it. Idle — and free — otherwise.

## Switching the AirPods mode (and the brief keyboard tap)

Heads-up: each time Air Defense flips noise control — once to engage ANC, once to
release it — it **momentarily grabs the keyboard for under a second**. If you happen
to be typing at that instant, a keystroke or two may not land in the app you're in.
It's two short taps per overflight (on, then off), not a continuous thing.

Here's why, because it isn't for lack of trying. The app switches the AirPods
listening mode by **automating the Control Center Sound popover through the
Accessibility API** — it opens the popover, clicks *Noise Cancellation* /
*Transparency*, then immediately closes it again. While that popover is open it
becomes the *key window* and holds the keyboard; closing it hands the keyboard back.
That open/close is the sub-second blip.

That route is a last resort, not a first choice. On **macOS 26 (Tahoe)** every
cleaner, invisible pathway turned out to be dead:

- The **Shortcuts** "Set Noise Control Mode" action is a **silent no-op**.
- The **private AVFoundation and IOBluetooth listening-mode APIs** that older menu-bar
  tools relied on now **report success but no longer reach the hardware** — `set`
  returns OK and nothing actually changes.
- **Synthetic hotkeys** posted to third-party helpers (e.g. AirBuddy) are **filtered**
  and ignored.

Driving Control Center via Accessibility is the **only** method that still audibly
changes the mode on Tahoe — which is why the two one-time setup steps below (grant
Accessibility, pin Sound to the menu bar) are required. If Apple restores a real
listening-mode API, this disruption goes away.

## Install

**Apple Silicon, macOS 15+.** One command sets up the backend and installs the
menu-bar app:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/air-defense/main/install.sh)"
```

It downloads a **self-contained** backend release (no Elixir/Erlang/Xcode needed),
installs it as a per-user LaunchAgent, and installs the app to `/Applications`.
**No API key needed** — it defaults to the free ADS-B feed. (If you later switch
the provider to FlightRadar24 in the app's settings, you paste the key there.)

The downloadable binaries are **code-signed with my Apple Developer ID and notarized
by Apple** (and stapled), so Gatekeeper opens them without the "unidentified
developer" warning — every release is built, signed, and notarized in CI.

Two one-time steps macOS requires and the script can't do for you:

1. **Grant Accessibility** — System Settings → Privacy & Security → Accessibility →
   enable **Air Defense**. (It drives Control Center to toggle ANC.)
2. **Pin Sound to the menu bar** — System Settings → Control Center → Sound →
   *Always Show in Menu Bar*.

Then click the menu-bar icon and **Start** a zone.

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

- **Data source** picker: `airplanes.live` (free, default) or
  `FlightRadar24`. Pick FR24 and a field appears to paste your API key (stored in
  the Keychain by the backend). Applies to all zones.
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

**Default (free):** `airplanes.live` is a community ADS-B aggregator — no API key, no
cost. All US commercial jets broadcast ADS-B, and busy metro areas near major
airports tend to have dense volunteer-receiver coverage, so traffic over the
approach/departure paths comes through complete. This is the default and what most
people should use. Be a good citizen: the small monitor zones keep request volume
low.

**Fallback (FlightRadar24):** the community feed depends on nearby hobbyist
receivers, so coverage varies by location. If `airplanes.live` doesn't reliably see
the low-altitude traffic over *your* spot — planes you can clearly hear that never
show up — switch the **Data source** to **FlightRadar24**, a commercial feed with
broad, consistent coverage. Sign up at
**[fr24api.flightradar24.com](https://fr24api.flightradar24.com/)** (the **Explorer**
plan is enough), then paste the API key into the app — it's stored only in your
macOS Keychain (service `air-defense-fr24`, `FR24_API_KEY` env fallback), **never**
committed or written to the launchd plist. FlightRadar24's `light` feed is billed
per flight returned, so small monitor zones keep usage low.

> The Explorer plan exposes no month-to-date usage or balance endpoint, so the
> credit bar is a **self-tally**: Air Defense counts every credit it spends and you
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
background so they never block a poll, and are capped to ~1,200/month to stay inside
the free tier. With no key, over the cap, or on a miss, the list simply falls back to
the raw callsign — everything else works identically.

## Layout

```
lib/lga_predictor/      Elixir service: geo, predictor, fr24 client, poller,
                        config_store, credit_ledger, actuator, api/router
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
- It's tuned for *my* apartment under *LaGuardia's* paths — the zones in
  [`config.example.json`](config.example.json) are mine. You'll draw your own
  monitor/ANC zones for wherever you are.
- It can only switch a device that's currently your active output and connected;
  pair it with Keep Sound Alive so the AirPods don't nap mid-session.
- ANC is toggled by automating Control Center — it needs the Accessibility grant and
  Sound pinned to the menu bar.

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
