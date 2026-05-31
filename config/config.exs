import Config

config :lga_predictor,
  # Home: Thornton Pl, Rego Park
  home_coords: {40.727, -73.860},

  # Noise zone — W→E band over the LIRR tracks ~1-2 blocks N of home, from
  # Woodhaven Blvd (west, ~-73.878) to the tracks. Widened west after live
  # observation: planes are audibly overhead at Woodhaven, ~20s before they
  # reached the old -73.870 edge. {:polygon, [{lat, lon}, ...]}.
  noise_zone:
    {:polygon,
     [
       {40.728, -73.880},
       {40.734, -73.880},
       {40.734, -73.850},
       {40.728, -73.850}
     ]},

  # FR24 query bounds {north, south, west, east}: Atlantic Ave (S), LIE/I-495 (N),
  # BQE/I-278 (W), open east to the noise-zone meridian.
  approach_box: {40.738, 40.678, -73.945, -73.850},
  altitude_ceiling_ft: 4500,
  altitude_floor_ft: 0,
  prediction_window_seconds: 120,
  poll_interval_ms: 15_000,
  session_duration_ms: 4 * 60 * 60 * 1000,

  # ANC window padding around the predicted overhead pass (engage this many
  # seconds before the path reaches the noise zone, release this many after it
  # clears). Bumped lead to 30s after a live pass engaged ~20s late; covers the
  # mode-change latency + poll granularity. Tunable from lived experience.
  anc_lead_seconds: 30,
  anc_tail_seconds: 15,
  fr24: %{sandbox?: false},
  # Localhost JSON API the Swift menu-bar control panel talks to.
  api_port: 4040

if config_env() == :test do
  import_config "test.exs"
end
