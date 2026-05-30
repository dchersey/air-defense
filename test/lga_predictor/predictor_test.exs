defmodule LgaPredictor.PredictorTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.FR24.Aircraft
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
