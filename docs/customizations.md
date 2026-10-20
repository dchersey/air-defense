# Optional route customizations

Air Defense has two independent layers:

- **Basic monitoring** reads the configured feed, tracks configured detection/noise zones, controls ANC, records individual passes, and checks quiet periods. It needs no route classifier or airport coordinates. Home coordinates improve release timing. New installations start here, with no zones until you draw or import them.
- **LGA / Rego Park** adds the author's arrival and departure route recognition, route history, passive high-approach color, and six-second departure timing calibration. Its geography, headings, altitude bands, aircraft filters and thresholds are personal calibrations. It is not a general LGA configuration for every neighborhood.

Choose the mode under Settings → Monitoring setup. Existing installations at the original home and airport coordinates migrate to the personal profile; other existing configurations default to Basic. An explicit choice always wins. Changing location or mode clears current classification evidence. Saved history is retained, but its chart is hidden in Basic mode.

## Adapt directly or with AI assistance

The customization entry point is `lib/lga_predictor/customizations/lga.ex`. Its implementation files live in `lib/lga_predictor/customizations/lga/`:

- `approach.ex`: arrival evidence, completed-pass votes, route selection and runway hints.
- `departure_track.ex`: takeoff/turn tracking and observed closest distances.

The existing Elixir module names remain stable for compatibility. The entry point exposes aircraft tracking, evidence, route selection, arrival headings, runway inference, departure observation and departure summaries. The poller calls those methods only when the profile is enabled. Generic zone detection and ANC do not depend on a route decision.

This is a source customization surface, not a dynamic plugin loader. Exported settings never execute code or select arbitrary module names. To add a new profile, create its module, register its identifier and validation in ConfigStore, add it to the Settings picker, and route the poller's profile calls to it. Update labels and route-history colors when introducing new route identifiers. Contributions are welcome; a universal visual route editor is not planned.

Work from receiver recordings of arrivals, departures, near misses, stale positions and reception gaps. Tests should show that the proposed profile distinguishes these cases and does not affect Basic monitoring. An AI assistant can help inspect recordings, implement the module and write replay tests, but location assumptions need real observations and review. Never use absence from an ANC zone alone as proof of an airport route.

## Portable settings

Settings → Export settings writes a versioned JSON file. It includes home/airport coordinates, receiver address, provider, zone geometry, timing, altitude/speed limits and profile choice. It excludes Keychain keys, URL user information/query parameters, unknown metadata, billing state, headphone identity, history and Mac preferences (including launch at login and announcement toggles). Treat coordinates and receiver addresses as personal information when sharing.

Settings → Import settings previews the mode, source, location and zones before replacement. Stop monitoring first. The backend validates the complete configuration before changing it and saves the previous configuration at `~/Library/Application Support/air-defense/config.json.before-import`. A malformed or unsupported file leaves the current configuration untouched. Credentials stay in the Keychain. Receiver URLs requiring query credentials need those credentials restored locally after import.

Imports replace the portable settings, including the zone list; they do not merge zones. Omitted portable fields take safe defaults. Local billing settings remain intact. To restore a backup manually, stop the backend, copy `config.json.before-import` to `config.json`, then restart it. The backup is raw local configuration, not the portable import format.
