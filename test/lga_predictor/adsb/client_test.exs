defmodule LgaPredictor.ADSB.ClientTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.ADSB.Client
  alias LgaPredictor.FR24.Aircraft

  # bounds {north, south, west, east}
  @box {40.80, 40.75, -73.92, -73.84}

  test "feeder API uses a remote point query and trims to the requested box" do
    response = %{"ac" => [%{"hex" => "inbox", "lat" => 40.76, "lon" => -73.87},
                           %{"hex" => "outside", "lat" => 41.2, "lon" => -73.87}]}
    opts = [provider: :airplanes_live, url: "http://broken-local.test/",
      req: [plug: fn conn ->
        assert conn.host == "api.airplanes.live"
        assert conn.request_path =~ "/v2/point/"
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        conn |> Plug.Conn.put_resp_content_type("application/json")
             |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end]]
    assert {:ok, [%Aircraft{hex: "inbox"}]} = Client.positions(@box, opts)
  end

  test "feeder authorization and malformed responses are failures, not empty skies" do
    for {status, body, error} <- [{403, %{"error" => "not a feeder"}, :http_error},
                                  {429, %{}, :http_error}, {200, %{}, :invalid_airplanes_response}] do
      result = Client.positions(@box, provider: :airplanes_live, req: [plug: fn conn ->
        conn |> Plug.Conn.put_resp_content_type("application/json")
             |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end])
      if error == :http_error,
        do: assert(result == {:error, {:http_error, status, body}}),
        else: assert(result == {:error, error})
    end
  end

  test "default provider fetches the configured local receiver" do
    response = %{"aircraft" => [%{"hex" => "inbox", "lat" => 40.76, "lon" => -73.87}]}
    opts = [url: "http://receiver.test/tar1090/data/aircraft.json", req: [plug: fn conn ->
      assert conn.host == "receiver.test"
      assert conn.request_path == "/tar1090/data/aircraft.json"
      conn |> Plug.Conn.put_resp_content_type("application/json")
           |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end]]
    assert {:ok, [%Aircraft{hex: "inbox"}]} = Client.positions(@box, opts)
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

    # readsb sends whichever vertical rate the aircraft transmits. Reading only
    # baro_rate reported ~a fifth of traffic as level, and the arrival filter then
    # rejected them for "not descending" — which is why the live final-approach gate
    # matched zero aircraft over 16 minutes of busy LGA traffic.
    test "falls back to geom_rate when the aircraft sends no baro_rate" do
      base = %{"hex" => "a1421b", "lat" => 40.76, "lon" => -73.87, "gs" => 200, "alt_baro" => 4525}

      assert [%Aircraft{vspeed_fpm: -704}] =
               Client.parse(%{"ac" => [Map.put(base, "geom_rate", -704)]}, @box)

      # baro_rate still wins when both are present.
      assert [%Aircraft{vspeed_fpm: -640}] =
               Client.parse(
                 %{"ac" => [base |> Map.put("baro_rate", -640) |> Map.put("geom_rate", -704)]},
                 @box
               )

      # Neither reported is still 0 — Geo.project does arithmetic on this.
      assert [%Aircraft{vspeed_fpm: 0}] = Client.parse(%{"ac" => [base]}, @box)
    end

    test "carries readsb's seen_pos as the position age" do
      base = %{"hex" => "a1421b", "lat" => 40.76, "lon" => -73.87, "gs" => 200, "alt_baro" => 4525}
      assert [%Aircraft{pos_age_s: 19.9}] = Client.parse(%{"ac" => [Map.put(base, "seen_pos", 19.9)]}, @box)
      assert [%Aircraft{pos_age_s: nil}] = Client.parse(%{"ac" => [base]}, @box)
    end

    test "drops aircraft outside the requested bounding box" do
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
