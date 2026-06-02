defmodule LgaPredictor.API.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias LgaPredictor.{Actuator, ConfigStore, History, Poller}
  alias LgaPredictor.API.Router

  @opts Router.init([])

  # Defend against a globally-named singleton lingering from a previous test
  # whose supervised teardown hasn't fully released the name yet under load.
  defp ensure_stopped(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> ref = Process.monitor(pid); Process.exit(pid, :kill); receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  setup do
    Enum.each([Poller, Actuator, History, ConfigStore], &ensure_stopped/1)

    path = Path.join(System.tmp_dir!(), "ndapi_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    start_supervised!(Actuator)
    start_supervised!({History, max: 50})
    start_supervised!({ConfigStore, path: path})

    start_supervised!(
      {Poller, fetcher: fn _ -> {:ok, []} end, poll_interval_ms: 50, session_duration_ms: 5_000}
    )

    :ok
  end

  defp call(method, path), do: conn(method, path) |> Router.call(@opts)

  # Spin (no sleep) until `fun` is true or we run out of tries — the actuator
  # engages via an async self-message, so the mode flips a beat after the cast.
  defp eventually(fun, tries \\ 100) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: {:cont, false}
    end)
  end

  test "GET /api/status returns session + mode JSON" do
    conn = call(:get, "/api/status")
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["active"] == false
    assert body["mode"] == "transparency"
    assert is_list(body["recent"])
    assert is_list(body["history"])
    assert is_list(body["zonesets"])
    assert body["engage_delta_seconds"] == 0
    assert body["release_delta_seconds"] == 0
  end

  test "PUT /api/config can set engage/release deltas (partial merge keeps zonesets)" do
    box = Jason.encode!(geojson_box())
    post_json("/api/zonesets", %{"name" => "Z", "monitor_geojson" => box, "anc_geojson" => box})

    assert put_json("/api/config", %{"engage_delta_seconds" => 8, "release_delta_seconds" => -3}).status == 200
    status = Jason.decode!(call(:get, "/api/status").resp_body)
    assert status["engage_delta_seconds"] == 8
    assert status["release_delta_seconds"] == -3
    # zoneset survived the partial config PUT
    assert length(Jason.decode!(call(:get, "/api/zonesets").resp_body)["zonesets"]) == 1
  end

  test "POST /api/session/start with a zoneset id then /stop toggles active" do
    put_json("/api/config", %{
      "zonesets" => [
        %{
          "id" => "z1",
          "name" => "SW",
          "enabled" => true,
          "monitor_zone" => geojson_box(),
          "anc_zones" => [geojson_box()]
        }
      ]
    })

    assert post_json("/api/session/start", %{"zoneset" => "z1"}).status == 200
    status = Jason.decode!(call(:get, "/api/status").resp_body)
    assert status["active"] == true
    assert Enum.find(status["zonesets"], &(&1["id"] == "z1"))["active"] == true

    assert post_json("/api/session/stop", %{"zoneset" => "z1"}).status == 200
    assert Jason.decode!(call(:get, "/api/status").resp_body)["active"] == false
  end

  test "POST /api/actuator/cover drives the desired mode + phase to anc/engaged" do
    assert post_json("/api/actuator/cover", %{"on_ms" => 0, "off_ms" => 10_000}).status == 200
    assert eventually(fn -> Jason.decode!(call(:get, "/api/status").resp_body)["mode"] == "anc" end)
    assert Jason.decode!(call(:get, "/api/status").resp_body)["anc_phase"] == "engaged"
  end

  test "zoneset CRUD: POST creates, GET lists with geojson strings, PATCH renames, DELETE removes" do
    box = Jason.encode!(geojson_box())

    created = post_json("/api/zonesets", %{"name" => "Arrivals SW", "monitor_geojson" => box, "anc_geojson" => box})
    assert created.status == 200
    out = Jason.decode!(created.resp_body)
    assert out["ok"] == true
    id = out["id"]
    assert is_binary(id)

    list = Jason.decode!(call(:get, "/api/zonesets").resp_body)["zonesets"]
    assert [z] = list
    assert z["id"] == id
    assert z["name"] == "Arrivals SW"
    # geojson comes back as a STRING, ready for the clipboard
    assert is_binary(z["monitor_geojson"])
    assert Jason.decode!(z["monitor_geojson"])["type"] == "Feature"

    assert patch_json("/api/zonesets/#{id}", %{"name" => "Renamed"}).status == 200
    assert [%{"name" => "Renamed"}] = Jason.decode!(call(:get, "/api/zonesets").resp_body)["zonesets"]

    assert call(:delete, "/api/zonesets/#{id}").status == 200
    assert Jason.decode!(call(:get, "/api/zonesets").resp_body)["zonesets"] == []
  end

  test "PATCH sets poll_interval_ms and GET reflects it (incl. clearing to null)" do
    box = Jason.encode!(geojson_box())
    id = Jason.decode!(post_json("/api/zonesets", %{"name" => "Z", "monitor_geojson" => box, "anc_geojson" => box}).resp_body)["id"]

    assert patch_json("/api/zonesets/#{id}", %{"poll_interval_ms" => 5000}).status == 200
    [z] = Jason.decode!(call(:get, "/api/zonesets").resp_body)["zonesets"]
    assert z["poll_interval_ms"] == 5000

    assert patch_json("/api/zonesets/#{id}", %{"poll_interval_ms" => nil}).status == 200
    [z] = Jason.decode!(call(:get, "/api/zonesets").resp_body)["zonesets"]
    assert z["poll_interval_ms"] == nil
  end

  test "zoneset writes validate: bad JSON / bad GeoJSON -> 422, unknown id -> 404" do
    box = Jason.encode!(geojson_box())

    assert post_json("/api/zonesets", %{"name" => "x", "monitor_geojson" => "{not json", "anc_geojson" => box}).status == 422
    assert post_json("/api/zonesets", %{"name" => "x", "monitor_geojson" => Jason.encode!(%{"foo" => 1}), "anc_geojson" => box}).status == 422

    assert patch_json("/api/zonesets/nope", %{"name" => "x"}).status == 404
    assert call(:delete, "/api/zonesets/nope").status == 404
  end

  test "POST /api/headphones updates the connected state in status" do
    assert post_json("/api/headphones", %{"connected" => false}).status == 200
    assert Jason.decode!(call(:get, "/api/status").resp_body)["headphones_connected"] == false

    assert post_json("/api/headphones", %{"connected" => true}).status == 200
    assert Jason.decode!(call(:get, "/api/status").resp_body)["headphones_connected"] == true
  end

  test "unknown route 404s as JSON" do
    conn = call(:get, "/nope")
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]
  end

  test "GET /api/config returns the current config" do
    body = Jason.decode!(call(:get, "/api/config").resp_body)
    assert body["global_ceiling_ft"] == 6000
    assert body["anc_latency_seconds"] == 2.0
    assert body["zonesets"] == []
  end

  test "PUT /api/config saves a zoneset and GET reflects it" do
    payload = %{
      "global_ceiling_ft" => 5000,
      "zonesets" => [
        %{
          "id" => "z1",
          "name" => "SW",
          "enabled" => true,
          "reckoning" => "constant",
          "monitor_zone" => geojson_box(),
          "anc_zones" => [geojson_box()]
        }
      ]
    }

    put = put_json("/api/config", payload)
    assert put.status == 200
    assert Jason.decode!(put.resp_body)["ok"] == true

    body = Jason.decode!(call(:get, "/api/config").resp_body)
    assert body["global_ceiling_ft"] == 5000
    assert [%{"id" => "z1"}] = body["zonesets"]
  end

  test "PUT /api/config with invalid data returns 422" do
    conn = put_json("/api/config", %{"zonesets" => [%{"name" => "no id"}]})
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]
  end

  defp put_json(path, map) do
    conn(:put, path, Jason.encode!(map))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp post_json(path, map) do
    conn(:post, path, Jason.encode!(map))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp patch_json(path, map) do
    conn(:patch, path, Jason.encode!(map))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp geojson_box do
    %{
      "type" => "Feature",
      "properties" => %{},
      "geometry" => %{
        "type" => "Polygon",
        "coordinates" => [
          [[-73.88, 40.73], [-73.85, 40.73], [-73.85, 40.75], [-73.88, 40.75], [-73.88, 40.73]]
        ]
      }
    }
  end
end
