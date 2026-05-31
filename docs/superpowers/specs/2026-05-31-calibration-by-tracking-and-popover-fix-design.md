# Per-flight ETA timing + popover-close fix — design

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
   later.

2. **Popover-close regression.** When the app drives the switch, it sometimes
   leaves the Control Center popover open and doesn't return focus to the
   previous app — though the same code path closed cleanly earlier the same day.

## The timing model: per-flight ETA (not learned calibration)

The fix is per-flight geometry, not a learned per-zoneset constant. The exact
thing that broke fixed-delay — flights detected at varying distances — is handled
for free: **each flight carries its own delay = (distance to the ANC zone) ÷ (its
own groundspeed)**, computed from a single detection poll.

This also errs in the safe direction. A banking/curving plane travels *more*
ground distance than the straight-line distance, and arrivals decelerate on final
approach — both mean the real plane arrives *later* than constant-speed math
predicts, so ANC engages slightly early rather than late. Early is tolerable;
late was the observed failure.

No learning, no sample buffer, no tracking process, no recalibration. Verification
("did it show up when predicted?") is done **by eye** on a live pass first (we log
the prediction inputs); an automated correction loop is deferred until the math is
shown to be biased.

## Relevant existing interfaces (do not break)

- `Poller` (`lib/lga_predictor/poller.ex`): `consider/4` branches on `trigger`;
  the `:assume` branch currently calls `assume_window/1` (fixed delay/duration).
  Reads config fresh each poll via injectable `config_fun`; FR24 via injectable
  `fetcher`; dedupes by hex; applies ramp filter + altitude ceiling; fires the
  `Actuator` `anc_latency_seconds` early.
- `Predictor.predict_overflight/2`: path-based dead reckoning (steps along the
  track). Stays as-is for `:predict` zonesets.
- `Geo`: `haversine_km/2`, `point_in_zone?/2`, `geojson_polygon/1`, `bbox/1`.
- `FR24.Aircraft`: has `:lat`, `:lon`, `:gspeed_kt`, `:track_deg`, `:alt_ft`,
  `:hex`.

## Part 1 — Per-flight ETA timing

Two small pure functions plus a Poller wiring change. **No new process; no
`ConfigStore`, `application.ex`, or `AircraftRegistry` changes.**

### `Geo` — distance to a zone

- **`distance_to_zone(point, {:polygon, pts}) :: float`** — kilometres from
  `point` to the nearest polygon boundary; `0.0` if inside. Implemented as the
  minimum point-to-segment great-circle distance over the polygon edges (planar
  approximation is fine at city scale).
- **`zone_distance_range(point, zone) :: {near, far}`** — `near` = above; `far` =
  the maximum distance from `point` to the zone's vertices. Used for dwell.

### `Predictor.predict_eta/3`

`predict_eta(aircraft, anc_zones, opts) :: %{enters_in, exits_in, dwell_seconds} | nil`

- `gs_km_s = gspeed_kt * 1.852 / 3600`. If `gspeed_kt` is nil or ~0 → `nil`
  (the Poller falls back to the manual fixed delay/duration).
- For each zone in `anc_zones`, take `{near, far} = Geo.zone_distance_range`.
  Across zones: `near = min(near_i)`, `far = max(far_i)` (single ANC zone is the
  common case).
- `enters_in = near / gs_km_s`
- `dwell_seconds = (far − near) / gs_km_s`  (chord-through-zone estimate)
- `exits_in = enters_in + dwell_seconds`
- A plane already inside a zone gives `near = 0` → `enters_in = 0` (engage now).

Heading-independent by construction — this is the key difference from
`predict_overflight` and why it survives banking/vectoring approaches.

### `Poller.consider` — `:assume` branch

Replace the fixed `assume_window(zoneset)` with:

```
case Predictor.predict_eta(ac, zoneset.anc_zones, ...) do
  nil    -> dispatch(assume_window(zoneset), ...)   # fallback: gs missing
  window -> dispatch(window, ...)
end
```

Everything else in the branch is unchanged: latency offset, hex dedupe, ceiling,
ramp filter. The `TRIGGER` log line gains `distance_km` and `gs_kt` so accuracy
can be judged by eye on a live pass (the "see if it showed up when predicted"
step). `assume_delay_seconds` / `assume_duration_seconds` remain in the config as
the fallback only; no config migration needed (`arr1`/`dep1` already
`trigger: :assume`).

`:predict` zonesets are untouched.

## Part 2 — Popover-close regression

Debugging task — evidence before structural change:

1. **Logging first** (`AncController.set` → `Log.line`): log `previousApp` bundle
   id, whether it equals our own bundle, each AX step's result, and a line after
   the reactivate. Confirms root cause from
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

- **`Geo.distance_to_zone` / `zone_distance_range`**: point outside → known
  distance; point inside → 0; point nearest an edge midpoint (not a vertex) →
  correct point-to-segment distance; `far` ≥ `near`.
- **`Predictor.predict_eta`**: aircraft at a known distance/gs → `enters_in ≈
  distance / gs`; dwell from `far − near`; multiple zones picks the soonest
  `enters_in`; `gspeed_kt` nil/0 → nil; already-inside → `enters_in = 0`.
- **`Poller`**: an `:assume` zoneset with an injected flight at a known
  distance/gs dispatches `Actuator.cover` with `on_ms ≈ (enters_in − latency)*1000`;
  falls back to the fixed window when groundspeed is missing.

## Out of scope (fast-follow, only if live testing shows bias)

- Automated verification: widen the poll to the union box (monitor∪ANC) and log
  predicted-vs-actual entry per flight.
- Per-zoneset correction factor applied to future ETAs.
- Direction sanity (skip a plane receding from the ANC zone).
- Accel-aware ETA for accelerating departures (constant-gs is the safe-early
  baseline).
- Adaptive per-zoneset poll interval; Swift settings pane; config backup.
