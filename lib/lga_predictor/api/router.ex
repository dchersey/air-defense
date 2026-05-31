defmodule LgaPredictor.API.Router do
  @moduledoc """
  Localhost-only JSON API for the SwiftUI menu-bar control panel. Bound to
  127.0.0.1 by Bandit (see `LgaPredictor.Application`), so no auth is needed.

    GET  /api/status          -> session state + desired acoustic mode + flights + graph
    POST /api/session/start   -> begin a 4h monitoring session
    POST /api/session/stop    -> end the session, return to Transparency
  """

  use Plug.Router

  alias LgaPredictor.{Actuator, ConfigStore, History, Poller}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/api/status" do
    send_json(conn, 200, status_payload())
  end

  post "/api/session/start" do
    result = Poller.start_session()
    send_json(conn, 200, %{ok: result == :ok, result: inspect(result)})
  end

  post "/api/session/stop" do
    Poller.stop_session()
    send_json(conn, 200, %{ok: true})
  end

  get "/api/config" do
    send_json(conn, 200, config_payload())
  end

  put "/api/config" do
    case ConfigStore.put(conn.body_params) do
      {:ok, _derived} -> send_json(conn, 200, %{ok: true, config: config_payload()})
      {:error, reason} -> send_json(conn, 422, %{error: to_string(reason)})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp status_payload do
    status = Poller.status()

    %{
      active: status.active?,
      mode: Actuator.mode(),
      session_ends_at: status.session_ends_at,
      polls: status.polls,
      approx_credits: status.approx_credits,
      recent: History.recent(50),
      # 12 buckets x 5 min = last hour of trigger counts, oldest -> newest
      history: History.counts_per_bucket(300, buckets: 12)
    }
  end

  # Echo the persisted config back as plain JSON (the raw form, so the UI
  # round-trips the GeoJSON it sent rather than the derived polygons/tuples).
  defp config_payload, do: ConfigStore.raw()

  defp send_json(conn, code, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(code, Jason.encode!(body))
  end
end
