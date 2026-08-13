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

    test "reads a local readsb aircraft.json (same records, different top-level key)" do
      # dump1090/readsb on your own Pi serve the whole picture under "aircraft"; the
      # public API uses "ac". Identical record shape, so both must map the same way.
      body = %{
        "now" => 1_786_650_000.0,
        "messages" => 1234,
        "aircraft" => [
          %{"hex" => "a1b2c3", "flight" => "AAL100  ", "lat" => 40.77, "lon" => -73.88,
            "gs" => 145.0, "alt_baro" => 1700, "track" => 70.0, "t" => "B738", "r" => "N1"},
          # outside the box — must still be trimmed client-side
          %{"hex" => "ffffff", "flight" => "FAR9999", "lat" => 41.90, "lon" => -72.10,
            "gs" => 300.0, "alt_baro" => 30000, "track" => 10.0}
        ]
      }

      assert [%Aircraft{} = ac] = Client.parse(body, @box)
      assert ac.hex == "a1b2c3"
      assert ac.callsign == "AAL100"
      assert ac.alt_ft == 1700
      assert ac.gspeed_kt == 145.0
      assert ac.type == "B738"
    end

    test "tolerates a missing/garbled body" do
      assert Client.parse(%{}, @box) == []
      assert Client.parse(%{"ac" => nil}, @box) == []
    end
  end
end
