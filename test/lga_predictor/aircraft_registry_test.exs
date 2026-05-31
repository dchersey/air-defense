defmodule LgaPredictor.AircraftRegistryTest do
  use ExUnit.Case

  alias LgaPredictor.AircraftRegistry

  test "observe returns the aircraft with accel 0 on first sighting" do
    reg = start_one()
    ac = %{hex: "A1", gspeed_kt: 200.0, alt_ft: 1500.0, lat: 40.7, lon: -73.9}
    [out] = AircraftRegistry.observe(reg, [ac], now: 1000)
    assert out.accel_kt_s == 0.0
  end

  test "derives accel from two samples (Δgs / Δt)" do
    reg = start_one()
    AircraftRegistry.observe(reg, [%{hex: "A1", gspeed_kt: 200.0}], now: 1000)
    [out] = AircraftRegistry.observe(reg, [%{hex: "A1", gspeed_kt: 260.0}], now: 1010)
    # +60 kt over 10 s = 6 kt/s
    assert_in_delta out.accel_kt_s, 6.0, 0.001
  end

  test "keys by hex, falling back to fr24_id" do
    reg = start_one()
    AircraftRegistry.observe(reg, [%{fr24_id: "f1", gspeed_kt: 100.0}], now: 1000)
    [out] = AircraftRegistry.observe(reg, [%{fr24_id: "f1", gspeed_kt: 140.0}], now: 1010)
    assert_in_delta out.accel_kt_s, 4.0, 0.001
  end

  test "prunes aircraft not seen within the TTL" do
    reg = start_one(ttl_seconds: 300)
    AircraftRegistry.observe(reg, [%{hex: "OLD", gspeed_kt: 100.0}], now: 1000)
    # A later observation of a different aircraft, long after OLD's TTL.
    AircraftRegistry.observe(reg, [%{hex: "NEW", gspeed_kt: 100.0}], now: 2000)
    refute AircraftRegistry.tracked?(reg, "OLD")
    assert AircraftRegistry.tracked?(reg, "NEW")
  end

  # Each test gets its own named registry so they don't share state.
  defp start_one(opts \\ []) do
    name = :"reg_#{System.unique_integer([:positive])}"
    start_supervised!({AircraftRegistry, [name: name] ++ opts}, id: name)
    name
  end
end
