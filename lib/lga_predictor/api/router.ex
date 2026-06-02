defmodule LgaPredictor.API.Router do
  @moduledoc """
  Localhost-only JSON API for the SwiftUI menu-bar control panel. Bound to
  127.0.0.1 by Bandit (see `LgaPredictor.Application`), so no auth is needed.

    GET  /api/status          -> session state (incl. per-zoneset) + mode + flights + graph
    POST /api/session/start   -> begin a 4h session; body {"zoneset": id} for one
                                 zoneset, or no body for all enabled zonesets
    POST /api/session/stop    -> end a session; body {"zoneset": id} for one,
                                 or no body for all
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
    result =
      case conn.body_params do
        %{"zoneset" => id} when is_binary(id) -> Poller.start_session(id)
        _ -> Poller.start_session()
      end

    send_json(conn, 200, %{ok: result == :ok, result: inspect(result)})
  end

  post "/api/headphones" do
    Poller.set_headphones(conn.body_params["connected"] == true)
    send_json(conn, 200, %{ok: true})
  end

  post "/api/session/stop" do
    case conn.body_params do
      %{"zoneset" => id} when is_binary(id) -> Poller.stop_session(id)
      _ -> Poller.stop_session()
    end

    send_json(conn, 200, %{ok: true})
  end

  # Manual ANC trigger — drives the same Actuator.cover the Poller uses, so the
  # menu-bar app mirrors it onto the headphones exactly as in a real session.
  # Engage in `on_ms`, release in `off_ms` (defaults 0). For testing without a flight.
  post "/api/actuator/cover" do
    on = trunc(conn.body_params["on_ms"] || 0)
    off = trunc(conn.body_params["off_ms"] || 0)
    Actuator.cover(on, off, conn.body_params["label"] || "manual")
    send_json(conn, 200, %{ok: true})
  end

  # Align the self-tally with the FR24 dashboard. Body: {"remaining": N} (the
  # balance shown in your FR24 profile) or {"used": N}. Sets the current month's
  # consumed total; live polling accumulates on top thereafter.
  post "/api/credits/seed" do
    budget = Application.get_env(:lga_predictor, :monthly_credit_budget, 60_000)

    used =
      case conn.body_params do
        %{"used" => u} when is_number(u) -> round(u)
        %{"remaining" => r} when is_number(r) -> max(budget - round(r), 0)
        _ -> nil
      end

    if used do
      LgaPredictor.CreditLedger.seed(used)
      send_json(conn, 200, %{ok: true, credits_used_month: used, credits_budget_month: budget})
    else
      send_json(conn, 422, %{error: "expected numeric 'remaining' or 'used'"})
    end
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

  get "/api/zonesets" do
    zonesets =
      Enum.map(ConfigStore.list_zonesets(), fn zs ->
        %{
          id: zs["id"],
          name: zs["name"],
          poll_interval_ms: zs["poll_interval_ms"],
          monitor_geojson: Jason.encode!(zs["monitor_zone"]),
          anc_geojson: Jason.encode!(List.first(zs["anc_zones"] || []))
        }
      end)

    send_json(conn, 200, %{zonesets: zonesets})
  end

  post "/api/zonesets" do
    with {:ok, attrs} <- zoneset_attrs(conn.body_params),
         {:ok, id} <- ConfigStore.add_zoneset(attrs) do
      send_json(conn, 200, %{ok: true, id: id})
    else
      {:error, reason} -> send_json(conn, 422, %{error: to_string(reason)})
    end
  end

  patch "/api/zonesets/:id" do
    with {:ok, fields} <- zoneset_fields(conn.body_params),
         :ok <- ConfigStore.update_zoneset(id, fields) do
      send_json(conn, 200, %{ok: true})
    else
      {:error, :not_found} -> send_json(conn, 404, %{error: "unknown zoneset"})
      {:error, reason} -> send_json(conn, 422, %{error: to_string(reason)})
    end
  end

  delete "/api/zonesets/:id" do
    case ConfigStore.delete_zoneset(id) do
      :ok -> send_json(conn, 200, %{ok: true})
      {:error, :not_found} -> send_json(conn, 404, %{error: "unknown zoneset"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # Build zoneset attrs for a create (name + both zones required).
  defp zoneset_attrs(params) do
    with {:ok, monitor} <- decode_geojson(params["monitor_geojson"]),
         {:ok, anc} <- decode_geojson(params["anc_geojson"]) do
      {:ok, %{"name" => params["name"] || "", "monitor_zone" => monitor, "anc_zones" => [anc]}}
    end
  end

  # Build a partial update map: only the fields present in the request.
  defp zoneset_fields(params) do
    acc = if name = params["name"], do: %{"name" => name}, else: %{}
    # Key present (value may be nil to clear back to the global interval).
    acc = if Map.has_key?(params, "poll_interval_ms"), do: Map.put(acc, "poll_interval_ms", params["poll_interval_ms"]), else: acc

    with {:ok, acc} <- maybe_geojson(acc, params, "monitor_geojson", "monitor_zone", & &1),
         {:ok, acc} <- maybe_geojson(acc, params, "anc_geojson", "anc_zones", &[&1]) do
      {:ok, acc}
    end
  end

  defp maybe_geojson(acc, params, in_key, out_key, wrap) do
    case Map.fetch(params, in_key) do
      :error ->
        {:ok, acc}

      {:ok, str} ->
        with {:ok, obj} <- decode_geojson(str), do: {:ok, Map.put(acc, out_key, wrap.(obj))}
    end
  end

  defp decode_geojson(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, obj} when is_map(obj) -> {:ok, obj}
      _ -> {:error, "invalid GeoJSON"}
    end
  end

  defp decode_geojson(_), do: {:error, "missing GeoJSON"}

  defp status_payload do
    status = Poller.status()
    config = ConfigStore.get()

    %{
      active: status.active?,
      mode: Actuator.mode(),
      anc_phase: Actuator.phase(),
      headphones_connected: status.headphones_connected,
      engage_delta_seconds: config.engage_delta_seconds,
      release_delta_seconds: config.release_delta_seconds,
      credits_used_month: credits_used(),
      credits_budget_month: Application.get_env(:lga_predictor, :monthly_credit_budget, 60_000),
      billing_reset_day: config.billing_reset_day,
      session_ends_at: status.session_ends_at,
      polls: status.polls,
      approx_credits: status.approx_credits,
      zonesets: status.zonesets,
      recent: History.recent(50),
      # 12 buckets x 5 min = last hour of trigger counts, oldest -> newest
      history: History.counts_per_bucket(300, buckets: 12)
    }
  end

  # Month-to-date credits consumed (nil if the ledger isn't running, e.g. tests).
  defp credits_used do
    if Process.whereis(LgaPredictor.CreditLedger),
      do: LgaPredictor.CreditLedger.month_to_date().used,
      else: nil
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
