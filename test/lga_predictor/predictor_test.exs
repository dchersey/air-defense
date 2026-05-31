defmodule LgaPredictor.PredictorTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.FR24.Aircraft
  alias LgaPredictor.Geo
  alias LgaPredictor.Predictor

  @home {40.728, -73.864}
  @zone {:circle, @home, 1.0}
  @opts [noise_zone: @zone, window_seconds: 90, altitude_ceiling_ft: 4500, step_seconds: 1]

  # An aircraft ~3.1 km south of home, heading due north at ~100 kt, low.
  defp inbound do
    %Aircraft{
      callsign: "TEST1",
      lat: 40.700,
      lon: -73.864,
      track_deg: 0.0,
      gspeed_kt: 100.0,
      vspeed_fpm: 0.0,
      alt_ft: 3000.0
    }
  end

  describe "predict_overflight/2" do
    test "an inbound low aircraft enters the zone within the window" do
      assert %{enters_in: enters, exits_in: exits} = Predictor.predict_overflight(inbound(), @opts)

      # crosses into the 1 km circle ~41 s out, leaves ~80 s out
      assert_in_delta enters, 41, 4
      assert_in_delta exits, 80, 4
      assert exits > enters
    end

    test "an aircraft heading away never enters" do
      away = %{inbound() | track_deg: 180.0}
      assert Predictor.predict_overflight(away, @opts) == nil
    end

    test "an aircraft above the altitude ceiling is ignored" do
      high = %{inbound() | alt_ft: 6000.0}
      assert Predictor.predict_overflight(high, @opts) == nil
    end

    test "an aircraft already over home enters at ~0 s" do
      overhead = %{inbound() | lat: 40.728}
      assert %{enters_in: enters} = Predictor.predict_overflight(overhead, @opts)
      assert enters <= 1
    end

    test "an accelerating aircraft reaches the zone sooner than constant speed" do
      ac = inbound()
      %{enters_in: constant} = Predictor.predict_overflight(ac, @opts)
      %{enters_in: accel} = Predictor.predict_overflight(ac, @opts ++ [accel_kt_s: 5.0])
      assert accel < constant
    end
  end

  describe "predict_traversal/2 (two-zone: separate on/off triggers)" do
    # On-zone is a band just north of start; off-zone further north. Plane heads
    # due north at 100 kt from lat 40.700.
    @on_zone {:polygon, [{40.710, -73.870}, {40.710, -73.858}, {40.716, -73.858}, {40.716, -73.870}]}
    @off_zone {:polygon, [{40.730, -73.870}, {40.730, -73.858}, {40.736, -73.858}, {40.736, -73.870}]}
    @topts [
      noise_on_zone: @on_zone,
      noise_off_zone: @off_zone,
      window_seconds: 120,
      altitude_ceiling_ft: 6000,
      step_seconds: 1
    ]

    test "engages when path reaches the on-zone, releases when it reaches the off-zone" do
      ac = inbound()
      assert %{engage_in: engage, release_in: release} = Predictor.predict_traversal(ac, @topts)
      assert engage > 0
      assert release > engage
    end

    test "an accelerating departure reaches both triggers sooner" do
      ac = inbound()
      %{engage_in: e0} = Predictor.predict_traversal(ac, @topts)
      %{engage_in: e1} = Predictor.predict_traversal(ac, @topts ++ [accel_kt_s: 8.0])
      assert e1 < e0
    end

    test "returns nil when the path never reaches the on-zone" do
      away = %{inbound() | track_deg: 180.0}
      assert Predictor.predict_traversal(away, @topts) == nil
    end

    test "ignores aircraft above the altitude ceiling" do
      high = %{inbound() | alt_ft: 7000.0}
      assert Predictor.predict_traversal(high, @topts) == nil
    end
  end

  describe "predict_eta/3 (distance ÷ groundspeed, heading-independent)" do
    # Square ANC zone east of the origin: lon 1..2, lat -0.5..0.5.
    @anc {:polygon, [{-0.5, 1.0}, {0.5, 1.0}, {0.5, 2.0}, {-0.5, 2.0}]}

    defp flying(gs) do
      %Aircraft{
        callsign: "ETA1",
        lat: 0.0,
        lon: 0.0,
        track_deg: 90.0,
        gspeed_kt: gs,
        vspeed_fpm: 0.0,
        alt_ft: 2000.0
      }
    end

    test "entry is near-edge distance over groundspeed; dwell is the chord over gs" do
      {near, far} = Geo.zone_distance_range({0.0, 0.0}, @anc)
      gs_km_s = 120.0 * 1.852 / 3600

      assert %{enters_in: enters, exits_in: exits, dwell_seconds: dwell} =
               Predictor.predict_eta(flying(120.0), [@anc], [])

      assert_in_delta enters, near / gs_km_s, 1.0e-6
      assert_in_delta dwell, (far - near) / gs_km_s, 1.0e-6
      assert_in_delta exits, enters + dwell, 1.0e-6
    end

    test "no usable groundspeed yields nil (fallback handled by the caller)" do
      assert Predictor.predict_eta(flying(0.0), [@anc], []) == nil
      assert Predictor.predict_eta(%{flying(120.0) | gspeed_kt: nil}, [@anc], []) == nil
    end

    test "a flight already inside the zone enters at 0 s" do
      inside = %{flying(120.0) | lon: 1.5}
      assert %{enters_in: +0.0} = Predictor.predict_eta(inside, [@anc], [])
    end

    test "caps dwell at :max_dwell_seconds and exits follows the cap" do
      # A slow aircraft yields a large uncapped dwell.
      %{dwell_seconds: uncapped} = Predictor.predict_eta(flying(30.0), [@anc], [])
      assert uncapped > 30

      assert %{enters_in: enters, exits_in: exits, dwell_seconds: dwell} =
               Predictor.predict_eta(flying(30.0), [@anc], max_dwell_seconds: 30)

      assert dwell == 30
      assert_in_delta exits, enters + 30, 1.0e-6
    end

    test "with multiple zones it picks the soonest entry" do
      # A nearer zone (lon 0.5..1) west of @anc.
      near_zone = {:polygon, [{-0.5, 0.5}, {0.5, 0.5}, {0.5, 1.0}, {-0.5, 1.0}]}
      %{enters_in: far_only} = Predictor.predict_eta(flying(120.0), [@anc], [])
      %{enters_in: with_near} = Predictor.predict_eta(flying(120.0), [near_zone, @anc], [])
      assert with_near < far_only
    end
  end

  describe "overflight_windows/2" do
    test "returns one window per qualifying aircraft, with the aircraft attached" do
      away = %{inbound() | callsign: "AWAY", track_deg: 180.0}
      high = %{inbound() | callsign: "HIGH", alt_ft: 6000.0}

      windows = Predictor.overflight_windows([inbound(), away, high], @opts)

      assert [window] = windows
      assert window.aircraft.callsign == "TEST1"
      assert window.enters_in > 0
    end

    test "returns an empty list when nothing qualifies" do
      away = %{inbound() | track_deg: 180.0}
      assert Predictor.overflight_windows([away], @opts) == []
    end
  end
end
