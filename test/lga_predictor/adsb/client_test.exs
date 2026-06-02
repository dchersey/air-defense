defmodule LgaPredictor.ADSB.ClientTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.ADSB.Client
  alias LgaPredictor.FR24.Aircraft

  # bounds {north, south, west, east}
  @box {40.80, 40.75, -73.92, -73.84}

  describe "bbox_to_circle/1" do
    test "centers the box and gives a radius (nm) that covers it" do
      {clat, clon, radius_nm} = Client.bbox_to_circle(@box)
      assert_in_delta clat, 40.775, 1.0e-6
      assert_in_delta clon, -73.88, 1.0e-6
      # half-diagonal of this ~3x4nm box is a couple nm; with margin, 1–10nm.
      assert radius_nm > 1.0 and radius_nm < 10.0
    end
  end

  describe "parse/2" do
    test "maps readsb records into Aircraft structs (shared shape with FR24)" do
      body = %{
        "ac" => [
          %{"hex" => "a7c849", "flight" => "EDV4631 ", "lat" => 40.76, "lon" => -73.87,
            "gs" => 142.5, "alt_baro" => 1725, "track" => 66.85, "t" => "E75L", "r" => "N321"}
        ]
      }

      assert [%Aircraft{} = ac] = Client.parse(body, @box)
      assert ac.hex == "a7c849"
      assert ac.callsign == "EDV4631"
      assert ac.lat == 40.76 and ac.lon == -73.87
      assert ac.gspeed_kt == 142.5
      assert ac.alt_ft == 1725
      assert ac.track_deg == 66.85
      assert ac.type == "E75L"
      assert ac.reg == "N321"
    end

    test "drops aircraft outside the bounding box (circle is trimmed to the box)" do
      body = %{
        "ac" => [
          %{"hex" => "inbox", "lat" => 40.76, "lon" => -73.87, "gs" => 140, "alt_baro" => 1500},
          %{"hex" => "north", "lat" => 41.20, "lon" => -73.87, "gs" => 300, "alt_baro" => 9000},
          %{"hex" => "west", "lat" => 40.76, "lon" => -74.50, "gs" => 250, "alt_baro" => 5000}
        ]
      }

      hexes = Client.parse(body, @box) |> Enum.map(& &1.hex)
      assert hexes == ["inbox"]
    end

    test "maps alt_baro \"ground\" to 0 (so the ramp filter drops it)" do
      body = %{"ac" => [%{"hex" => "grnd", "lat" => 40.76, "lon" => -73.87, "gs" => 0, "alt_baro" => "ground"}]}
      assert [%Aircraft{alt_ft: 0}] = Client.parse(body, @box)
    end

    test "tolerates a missing/garbled body" do
      assert Client.parse(%{}, @box) == []
      assert Client.parse(%{"ac" => nil}, @box) == []
    end
  end
end
