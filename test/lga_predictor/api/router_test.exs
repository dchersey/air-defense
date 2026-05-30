defmodule LgaPredictor.API.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias LgaPredictor.{Actuator, History, Poller}
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
    Enum.each([Poller, Actuator, History], &ensure_stopped/1)

    start_supervised!(Actuator)
    start_supervised!({History, max: 50})

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
end
