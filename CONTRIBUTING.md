# Contributing

Thanks for your interest! This started as a personal tool for one apartment under
one airport's flight paths, so expect some rough edges and author-specific
defaults. Local features—including low/high/river route classification, background
activity, route history, and acoustic timing—are specific to the author's apartment
and LaGuardia. There is no planned maintainer work on a setup or adaptation workflow
for other locations. Contributions that adapt these features or make them more general
(without adding bloat) are welcome.

Position sources are the local ADS-B receiver (default) and paid FlightRadar24.
The airplanes.live API is suspended and its provider is disabled; new work should
not depend on it.

## Layout

- `lib/lga_predictor/` — the headless Elixir/OTP service (the internal module
  namespace is still `LgaPredictor` for historical reasons):
  - `poller.ex` — per-zoneset polling, lock-on, ETA timing, dispatch.
  - `predictor.ex` / `geo.ex` — dead-reckoning + geospatial math.
  - `actuator.ex` — desired-ANC-mode state machine.
  - `config_store.ex` — zonesets + global settings (JSON-persisted).
  - `credit_ledger.ex` — FR24 credit self-tally with a billing cycle.
  - `fr24/client.ex` — FlightRadar24 API client.
  - `adsb/client.ex` — local receiver client.
  - `approach.ex` / `route_history.ex` — local route classification and durable history.
  - `api/router.ex` — the localhost-only JSON API the app talks to.
- `macos/ControlPanel/` — the SwiftUI menu-bar app (control panel + the ANC
  switch via private CoreBluetooth, with Control Center accessibility fallback).
- `install.sh` — the end-user curl installer (backend release + app).
- `priv/launchd/` — the dev LaunchAgent (`install.sh` here runs from source).

## Build & test

Backend (requires Elixir ~> 1.19 / OTP 29):

```sh
mix deps.get
mix test
mix compile --warnings-as-errors
./priv/launchd/install.sh        # run as a local LaunchAgent from source (dev)
```

App (requires macOS 15+ and a recent Swift toolchain):

```sh
cd macos/ControlPanel && swift build
swift test
../build_app.sh --here           # build the .app without installing
../build_app.sh                  # build, sign, install to /Applications
```

CI runs `mix test` (Linux), plus a release Swift build and `swift test` (macOS),
on every push/PR.

## Guidelines

- TDD: add or update tests for any logic change; keep `mix test` green.
- Keep the JSON API **localhost-only** — it has no auth by design.
- Never commit an FR24 key. The client reads it from the Keychain (service
  `air-defense-fr24`) with an `FR24_API_KEY` env fallback.
- The optional [Keep Sound Alive](https://github.com/dchersey/keep-sound-alive)
  integration must stay **best-effort** — Air Defense has to work without it.

## Reporting issues

Please include your macOS version, your AirPods/headphone model, and any relevant
lines from `~/Library/Logs/air-defense.log` (service) or
`~/Library/Logs/air-defense-app.log` (menu-bar app).
