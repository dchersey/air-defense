defmodule LgaPredictor.FR24.AircraftTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.FR24.Aircraft

  defp light_record do
    %{
      "fr24_id" => "3a1b2c3",
      "hex" => "A12345",
      "callsign" => "AAL123",
      "lat" => 40.77,
      "lon" => -73.9,
      "track" => 220,
      "alt" => 3200,
      "gspeed" => 250,
      "vspeed" => -640,
      "squawk" => "1200",
      "timestamp" => "2026-05-30T14:01:00Z",
      "source" => "ADSB"
    }
  end

  describe "from_fr24/1" do
    test "maps FR24 light fields onto the struct with predictor-friendly names" do
      ac = Aircraft.from_fr24(light_record())

      assert ac.fr24_id == "3a1b2c3"
      assert ac.callsign == "AAL123"
      assert ac.hex == "A12345"
      assert ac.lat == 40.77
      assert ac.lon == -73.9
      assert ac.track_deg == 220
      assert ac.alt_ft == 3200
      assert ac.gspeed_kt == 250
      assert ac.vspeed_fpm == -640
      assert ac.timestamp == "2026-05-30T14:01:00Z"
    end

    test "tolerates missing optional fields (light has no aircraft type)" do
      ac = Aircraft.from_fr24(Map.drop(light_record(), ["callsign", "vspeed"]))

      assert ac.callsign == nil
      assert ac.vspeed_fpm == 0
      assert ac.fr24_id == "3a1b2c3"
    end
  end

  describe "parse_positions/1" do
    test "parses the {\"data\": [...]} envelope into a list of structs" do
      body = %{"data" => [light_record(), Map.put(light_record(), "fr24_id", "other")]}
      [first, second] = Aircraft.parse_positions(body)

      assert first.fr24_id == "3a1b2c3"
      assert second.fr24_id == "other"
    end

    test "returns an empty list when there is no data" do
      assert Aircraft.parse_positions(%{"data" => []}) == []
      assert Aircraft.parse_positions(%{}) == []
    end
  end
end
