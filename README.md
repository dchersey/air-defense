# Air Defense

[![CI](https://github.com/dchersey/air-defense/actions/workflows/ci.yml/badge.svg)](https://github.com/dchersey/air-defense/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

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

- **Tracks live traffic** via the FlightRadar24 API and predicts, per flight,
  *when* it will be overhead — distance to the noisy zone ÷ ground speed.
- **Engages ANC just before** the plane arrives and **releases it** once the plane
  clears — so you're only cancelling when it actually matters.
- **Only watches small boxes.** You draw a tiny **monitor zone** upstream; that's
  the only thing polled (FR24 bills per flight returned), so it stays cheap.
- **Locks on.** Once it's caught an inbound it stops polling that zone until the
  plane clears — no wasted credits re-detecting the same jet.
- **Pauses when you take the AirPods off** (or switch output away) and resumes when
  they're back, so it never toggles a device that isn't listening.
- **Tracks your FR24 credits** against your monthly allotment with a pace bar, so
  you can see at a glance whether you're burning them faster than the month.
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

Sessions are manual: hit **Start** on a zone when the planes start, and it runs for
~4 hours or until you stop it. Idle — and free — otherwise.

## Install

**Apple Silicon, macOS 15+.** One command sets up the backend, stores your FR24
key, and installs the menu-bar app:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/air-defense/main/install.sh)"
```

It downloads a **self-contained** backend release (no Elixir/Erlang/Xcode needed),
installs it as a per-user LaunchAgent, prompts for your FlightRadar24 API key
(stored only in your Keychain), and installs the notarized app to `/Applications`.

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

## Using it

- **Start / Stop** per zone from the menu — each zone runs its own session.
- **Edit zones** inline: paste GeoJSON, or "Open in geojson.io" to draw a box over
  the map and bring it back. Set a per-zone poll interval.
- **ANC timing offset** sliders nudge the computed engage/release moments ±15 s.
- The **credit bar** shows what's left against your monthly FR24 allotment, with a
  hashmark at the day-of-cycle so you can tell if you're ahead of pace. Hit **Sync**
  to enter the *remaining* balance from your FR24 dashboard and the **reset day** of
  your billing cycle.

## Getting an FR24 key

You need a [FlightRadar24 API](https://fr24api.flightradar24.com/) key — the
**Explorer** plan is enough. Air Defense polls `light` flight positions (billed per
flight returned), so keeping monitor zones small keeps usage low. The key is stored
only in your macOS Keychain (service `air-defense-fr24`), with an `FR24_API_KEY`
env-var fallback — **never** committed, never written to the launchd plist.

> The Explorer plan exposes no month-to-date usage or balance endpoint, so the
> credit bar is a **self-tally**: Air Defense counts every credit it spends and you
> periodically Sync it to the dashboard number. It rolls over on your billing
> anniversary (the reset day you set).

## Layout

```
lib/lga_predictor/      Elixir service: geo, predictor, fr24 client, poller,
                        config_store, credit_ledger, actuator, api/router
macos/ControlPanel/     SwiftUI menu-bar app (control panel + ANC actuator)
macos/build_app.sh      Builds the app + installs to /Applications
install.sh              End-user curl installer (backend release + app)
priv/launchd/           Dev LaunchAgent (runs the service from source)
scripts/                One-off FR24 probes + the historic backtest
test/                   ExUnit tests (TDD)
```

## Limitations

- **Apple Silicon, macOS 15+.** Intel: build from source.
- It's tuned for *my* apartment under *LaGuardia's* paths — the default zones are
  mine. You'll draw your own monitor/ANC zones for wherever you are.
- It can only switch a device that's currently your active output and connected;
  pair it with Keep Sound Alive so the AirPods don't nap mid-session.
- ANC is toggled by automating Control Center — it needs the Accessibility grant and
  Sound pinned to the menu bar.

## License

MIT — see [LICENSE](LICENSE).
