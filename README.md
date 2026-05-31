# Noise Defence — LGA overflight ANC predictor

A personal macOS tool that predicts when aircraft departing/arriving at LaGuardia
will pass over a specific apartment (Rego Park, Queens) and automatically switches
AirPods Max between **Transparency** and **Active Noise Cancellation** so windows
can stay open without the plane noise — and without being isolated when it's quiet.

A headless **Elixir/OTP** service does the prediction and exposes a localhost JSON
API; a small **SwiftUI menu-bar app** is the control panel and performs the actual
ANC switch.

## How it works

- **Data:** FlightRadar24 API (`light` flight positions). Billed per flight
  returned, so only small **monitor zones** are polled.
- **Model (zonesets):** a *zoneset* = one **monitor zone** (the only thing polled)
  + one or more **ANC zones** (where it's loud, never polled) + a reckoning mode.
  When a flight is detected in a monitor zone, its path is **dead-reckoned**
  forward; ANC **engages** on predicted entry into an ANC zone and **releases** on
  predicted exit. Departures accelerate along their arc, so reckoning can be
  `:accelerating` (acceleration measured from successive samples).
- **Timing:** predictions assume zero actuator latency; a configurable
  `anc_latency_seconds` (default 2 s) fires each switch slightly early so the mode
  has changed by the predicted moment.
- **Sessions:** manual — start a session when planes start; it runs ~4 h or until
  stopped. Idle (and free) otherwise.

## Status (2026-05-31)

Active development — the architecture is mid-refactor from a single hardcoded
geofence to **user-configurable zonesets**. `mix test` → 63 tests, 0 failures.

**Working and validated:**
- Prediction engine: `Geo` (distance, dead-reckoning incl. acceleration, polygon
  zones, GeoJSON loading), `Predictor`, `AircraftRegistry` (per-flight accel),
  `FR24.Client`, `Zones`.
- ANC actuator (`macos/ControlPanel`): drives Control Center via the Accessibility
  API and restores focus/closes the popover with `activate(.activateIgnoringOtherApps)`.
  Verified switching real AirPods Max on macOS 26 (Tahoe). *(All no-UI private-API
  routes — Shortcuts, AVFoundation, IOBluetooth, AirBuddy hotkeys — were tried and
  are dead on Tahoe.)*
- FR24 key stored in the **macOS Keychain** (`security`), env-var fallback.
- Autostart: **LaunchAgent** for the headless service (`priv/launchd/`) + the
  app's **Launch at Login** toggle; app installs to `/Applications`.
- Localhost API: `GET /api/status`, `POST /api/session/{start,stop}`,
  `GET/PUT /api/config`.
- `ConfigStore`: user config (global ceiling, ANC latency, zonesets) as JSON at
  `~/Library/Application Support/noise-defence/config.json`.
- A hands-free **arrival** overflight was confirmed end-to-end on a live pass.

**In progress / next:**
- Swift **settings pane** to edit zonesets (paste GeoJSON), global ceiling, ANC
  latency, and trigger calibration.
- **Calibration** of acceleration (auto during a session + a manual button).
- **GitHub backup** of `config.json`.
- A flight-**capture map** overlay to draw zones over observed traffic.
- A real hands-free **departure** test (departures are a distinct, accelerating
  pattern not yet validated live).

See `docs`/the planning notes for the full design. The implementation plan lives
outside the repo (in the assistant's plan file).

## Layout

```
lib/lga_predictor/      Elixir service: geo, predictor, fr24 client, poller,
                        config_store, actuator (desired-mode), api/router, ...
macos/ControlPanel/     SwiftUI menu-bar app (control panel + ANC actuator)
macos/AncProbe/         Throwaway AX diagnostics used while finding the actuator
macos/build_app.sh      Builds the app + installs to /Applications
priv/launchd/           LaunchAgent template + install.sh
scripts/                One-off FR24 probes + the historic backtest / calibration capture
test/                   ExUnit tests (TDD)
```

## Setup / run (dev)

```sh
# 1. FR24 key into Keychain (one time):
security add-generic-password -a "$USER" -s "noise-defence-fr24" -A -w

# 2. Elixir service (headless; or install the LaunchAgent for autostart):
mix deps.get
iex -S mix                      # API on http://127.0.0.1:4040
#   or: ./priv/launchd/install.sh   (autostart at login)

# 3. Menu-bar app:
./macos/build_app.sh            # builds + installs to /Applications
#   grant Accessibility to "LGA Overflight" on first launch;
#   pin Sound to the menu bar (Control Center settings)

mix test                        # 63 tests
```

Requires macOS 26 (Tahoe), Apple Silicon, Elixir 1.19 / OTP 29, Swift 6, AirPods Max.

## Privacy / secrets

The FR24 API key lives in the macOS Keychain (or an env var) — **never** in the
repo or the launchd plist. No keys are committed.
