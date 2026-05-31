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

  test "GET /api/status returns session + mode JSON" do
    conn = call(:get, "/api/status")
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["active"] == false
    assert body["mode"] == "transparency"
    assert is_list(body["recent"])
    assert is_list(body["history"])
  end

  test "POST /api/session/start then /stop toggles active" do
    assert call(:post, "/api/session/start").status == 200
    assert Jason.decode!(call(:get, "/api/status").resp_body)["active"] == true

    assert call(:post, "/api/session/stop").status == 200
    assert Jason.decode!(call(:get, "/api/status").resp_body)["active"] == false
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
