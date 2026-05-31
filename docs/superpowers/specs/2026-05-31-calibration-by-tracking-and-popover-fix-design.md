# Calibration-by-tracking + popover-close fix — design

Date: 2026-05-31
Status: approved (design); not yet implemented

## Context

`noise-defence` auto-switches AirPods Max between Transparency and ANC when LGA
aircraft will be loud over Rego Park. The full pipeline is proven live: FR24
detects a flight in a zoneset's **monitor zone** → the `:assume` trigger fires
ANC → the Elixir service exposes desired mode over a localhost API → a signed
SwiftUI menu-bar app polls every 2s and drives Control Center via Accessibility.

Two problems surfaced in live testing:

1. **Timing is wrong.** A fixed `assume_delay_seconds` can't work: the `arr1`
   monitor zone is big and far from the noise zone, so flights are detected at
   widely varying distances from the ANC zone. ANC fired immediately on monitor
   entry and dropped 10s later, while the plane reached the noise zone minutes
   later. The fix is to **measure** the real delay/dwell per zoneset by tracking
   flights, rather than guessing a constant.

2. **Popover-close regression.** When the app drives the switch, it sometimes
   leaves the Control Center popover open and doesn't return focus to the
   previous app — though the same code path closed cleanly earlier the same day.

This supersedes the discarded fixed-delay tuning and the `:eta` idea.

## Relevant existing interfaces (do not break)

- `Poller` (`lib/lga_predictor/poller.ex`): iterates enabled zonesets each tick;
  `consider/4` branches on `trigger`; `:assume` fires `assume_window/1` using
  `assume_delay_seconds`/`assume_duration_seconds`. Reads config fresh each poll
  via injectable `config_fun`; FR24 via injectable `fetcher`.
- `ConfigStore` (`config_store.ex`): GenServer, JSON at
  `~/Library/Application Support/noise-defence/config.json`. `get/1` returns the
  derived (polygon + `monitor_box`) form; `raw/1` returns string-keyed JSON;
  `put/1` validates + atomic-writes + bumps `version`.
- `Predictor.predict_overflight/2`: dead-reckons; returns
  `%{enters_in, exits_in, dwell_seconds}` or nil. Honors `:accel_kt_s`.
- `AircraftRegistry.observe/3`: enriches aircraft with `:accel_kt_s` across polls.
- `Geo`: `haversine_km/2`, `project/3` (accel-aware), `point_in_zone?/2`,
  `geojson_polygon/1`, `bbox/1`.
- `FR24.Client.positions(box, :light, opts)`: queries a **bounding box** (there
  is no per-hex lookup); 6 cr per returned aircraft.
- Swift `AncController.set(_:)` + `Model.applyModeIfChanged/1`.

## Part 1 — Calibration-by-tracking

### Module: `LgaPredictor.Calibration` (new GenServer)

A dedicated GenServer, not folded into `Poller`. The Poller does cheap per-flight
detection on one cadence; tracking is a stateful, variable-cadence side activity
running ~5 flights/hour. Separation keeps the Poller simple and the tracker
testable with an injected fetcher + clock. The Poller only *notifies* the tracker.

#### State

Per `:assume` zoneset:
- `armed?` — collecting samples this hour (true from session-start / hourly tick
  until 5 samples gathered).
- `samples` — list of `%{delay, dwell}`, target 5.
- `last_calibrated_at`.

In-flight tracked aircraft: `hex => %{zoneset_id, first_seen_ts, entry_ts | nil, last_ac}`.

Injectable: `:fetcher` (`box -> {:ok,[ac]} | {:error,_}`), `:config_fun`, `:clock`
(unix seconds), for offline tests.

#### API

- `track(zoneset_id, aircraft, first_seen_ts)` — called by `Poller` on each
  `:assume` detection. Begins tracking iff that zoneset is `armed?`, has <5
  samples, and the hex isn't already tracked.
- `arm_all/0`, `reset/0` — driven by `Poller` on session start / stop.
- `status/0` — samples collected + `last_calibrated_at` per zoneset (for API/UI).

#### Re-poll loop (union box, adaptive cadence)

1. The tracker runs its timer only while ≥1 in-flight tracked aircraft exists
   (idle otherwise → zero credits).
2. Each tick, for every zoneset that has tracked flights, fetch its **union box**
   = bbox of `monitor_zone ∪ anc_zones` (one FR24 call covers all that zoneset's
   tracked flights). Add `length(results) * 6` to a calibration credit counter.
   Match tracked hexes within the results.
3. For each tracked flight, test `Geo.point_in_zone?` against the zoneset's
   `anc_zones`:
   - first sample inside → set `entry_ts`; `delay = entry_ts − first_seen_ts`.
   - first sample back outside after entry → `dwell = exit_ts − entry_ts`; push
     `%{delay, dwell}` and stop tracking that flight.
4. **Adaptive cadence:** for flights not yet in-zone, predict seconds-to-entry by
   reusing `Predictor.predict_overflight(ac, noise_zone: anc_zone, …).enters_in`
   (min across `anc_zones`; pass `accel_kt_s` from `AircraftRegistry` when the
   zoneset reckons `:accelerating`). Next tick = **2s** if the soonest predicted
   entry across all tracked flights ≤ 10s, else **10s**.
5. **Safety:** drop a tracked flight that never enters within `window_seconds`
   (120s) or that disappears from the box for several consecutive ticks
   (go-arounds / wrong-runway). Logged.

#### On 5 samples for a zoneset

- `delay = min(delays)` (earliest — engage no later than the soonest observed).
- `dwell = max(dwells)` (longest — hold no shorter than the longest observed).
- `ConfigStore.update_zoneset(id, %{"assume_delay_seconds" => delay,
  "assume_duration_seconds" => dwell, "calibrated_at" => now})` — **overwrites**
  the manual `assume_*` values (user's choice).
- Disarm that zoneset; `log` result + calibration credits spent.

#### Hourly recalibration

A `:recalibrate` timer started on `arm_all`, cancelled on `reset`, re-arms every
zoneset and clears its samples once per hour while the session is active.

### Supporting changes

- **`ConfigStore.update_zoneset(name \\ __MODULE__, id, merge_map)`** — atomic
  read-modify-write inside the GenServer: find zoneset by `id`, `Map.merge` the
  string-keyed fields, validate, persist, bump `version`. Returns
  `{:ok, derived}` / `{:error, reason}` (bad id → error). Avoids a
  read-modify-write race from the tracker.
- **Validation/derivation:** `validate_zoneset` tolerates the new `calibrated_at`
  key; `derive_zoneset` surfaces it.
- **Union bbox:** reuse `Patterns.union_box/1` if it fits; else add
  `Geo.union_box([zone]) :: {n,s,w,e}`.
- **`Poller.consider`** — for `:assume` zonesets, after `dispatch`, also
  `Calibration.track(zoneset.id, ac, now)` guarded by `Process.whereis`
  (like `History`). Normal ANC firing is unchanged: it keeps using the current
  `assume_*` values; once calibration overwrites them the next poll picks them up
  (Poller reads config fresh each tick).
- **`Poller` session lifecycle** — `Calibration.arm_all()` on start_session,
  `Calibration.reset()` on end_session (both guarded by `Process.whereis`).
- **`application.ex`** — supervise `Calibration` after `ConfigStore` /
  `AircraftRegistry` and before `Poller`.

### Cost

The union box is large for `arr1`, so 2s-cadence re-polls near entry can return
several aircraft each. Bounded to ~5 flights/hour, idle otherwise. Calibration
credits are logged separately so they can be watched on the first live run.

## Part 2 — Popover-close regression

Debugging task — evidence before structural change:

1. **Logging first** (`AncController.set` → `Log.line`): log `previousApp`
   bundle id, whether it equals our own bundle, each AX step's result, and a line
   after the reactivate. Confirms root cause from
   `~/Library/Logs/noise-defence-app.log` on the next live pass.
2. **Guard `previousApp == self / nil`** — prime suspect: when the menu-bar app
   has been clicked, `frontmostApplication` is our LSUIElement agent, so
   reactivating it never makes the popover resign key. Fix: if `previousApp` is
   nil or our own bundle id, activate a guaranteed *other* app (Finder) to force
   the popover to resign.
3. **Serialize `set()`** — an `isApplying` reentrancy gate in
   `Model.applyModeIfChanged` so back-to-back desired-mode changes (7 arrivals in
   a row) can't launch a second AX sequence mid-flight.
4. Keep the verified cc2 recipe (0.5s open + `.activateIgnoringOtherApps`); no
   timing change unless the logs say otherwise.

No unit tests for the AX path (untestable); verified by ear/eye on a live pass.

## Testing (TDD, commit-per-unit, suite stays green)

- **`Calibration`**: injected fetcher replays a flight crossing monitor → ANC
  zone + injected clock. Assert delay/dwell capture; earliest-delay/longest-dwell
  aggregation after 5 samples (and the `ConfigStore.update_zoneset` write);
  adaptive 2s-vs-10s decision; hourly re-arm; never-enters timeout; idle when no
  tracked flights.
- **`ConfigStore.update_zoneset`**: temp path — persist + version bump + bad-id
  error + `calibrated_at` round-trips.
- **`Poller`**: detection notifies `Calibration`; no-ops cleanly when
  `Calibration` isn't running.
- **`Geo.union_box`** (if added): bbox of multiple zones.

## Out of scope (fast-follow)

- Adaptive per-zoneset main poll interval (separate request).
- Swift settings pane surfacing `calibrated_at` / a manual Calibrate button.
- GitHub backup of `config.json`; flight-capture map.
