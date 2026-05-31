defmodule LgaPredictor.Poller do
  @moduledoc """
  The session loop. Each **zoneset** can have its own independent monitoring
  session (started/stopped by id from the control panel); both arrival and
  departure zonesets can run at once. While any session is active the poller
  polls FR24 once per `poll_interval_ms` for each **running** zoneset's monitor
  zone (the only thing that costs credits), predicts whether each detected flight
  will pass through that zoneset's ANC zones, and schedules ANC engage/release
  with the `Actuator`. Each session runs for `session_duration_ms` (4 h) or until
  stopped.

  Idle by default — nothing is polled (and no credits spent) until a session is
  started. Stats (`polls`, `credits`, the actioned-dedupe set) reset when starting
  from fully idle and accumulate across concurrently-running sessions.

  Config (zonesets, global ceiling, ANC latency) comes from `ConfigStore` via an
  injectable `:config_fun`. FR24 fetching is injectable via `:fetcher` (a
  `box -> {:ok, [aircraft]} | {:error, _}` function) so the loop is testable offline.

  ANC timing: predictions assume zero actuator latency; each engage/release command
  is issued `anc_latency_seconds` EARLY so the mode is actually changed by the
  predicted moment. A flight is actioned at most once per session (de-duped by hex).
  """

  use GenServer
  require Logger

  alias LgaPredictor.{Actuator, ConfigStore, History, Predictor}
  alias LgaPredictor.FR24.Client

  @credits_per_aircraft 6

  ## API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Begin a monitoring session for a single zoneset by id."
  def start_session(zoneset_id) when is_binary(zoneset_id),
    do: GenServer.call(__MODULE__, {:start_session, zoneset_id})

  @doc "Begin sessions for every enabled zoneset."
  def start_session, do: GenServer.call(__MODULE__, :start_session)

  @doc "End the monitoring session for a single zoneset by id."
  def stop_session(zoneset_id) when is_binary(zoneset_id),
    do: GenServer.call(__MODULE__, {:stop_session, zoneset_id})

  @doc "End all sessions, stop polling, return to Transparency."
  def stop_session, do: GenServer.call(__MODULE__, :stop_session)

  @doc "Session status: active?, per-zoneset session state, polls, credits."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Report whether the AirPods are the active output. When disconnected, an active
  session keeps its timer running but PAUSES polling (no FR24 credits) — there's
  nothing to control — and resumes automatically when they reconnect.
  """
  def set_headphones(connected) when is_boolean(connected),
    do: GenServer.call(__MODULE__, {:set_headphones, connected})

  ## Server

  @impl true
  def init(opts), do: {:ok, build_state(opts)}

  @impl true
  def handle_call({:start_session, id}, _from, state) do
    cond do
      Map.has_key?(state.sessions, id) -> {:reply, {:error, :already_active}, state}
      not zoneset_exists?(id, state) -> {:reply, {:error, :unknown_zoneset}, state}
      true -> {:reply, :ok, start_one(state, id)}
    end
  end

  def handle_call(:start_session, _from, state) do
    state =
      Enum.reduce(enabled_ids(state), state, fn id, st ->
        if Map.has_key?(st.sessions, id), do: st, else: start_one(st, id)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:stop_session, id}, _from, state), do: {:reply, :ok, stop_one(state, id)}
  def handle_call(:stop_session, _from, state), do: {:reply, :ok, stop_all(state)}

  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  def handle_call({:set_headphones, connected}, _from, state) do
    if connected != state.headphones_connected do
      Logger.info("[poller] headphones #{if connected, do: "connected — resuming", else: "disconnected — pausing"}")
      # Clear any held mode on disconnect; polling resumes fresh on reconnect.
      unless connected, do: Actuator.reset()
    end

    {:reply, :ok, %{state | headphones_connected: connected}}
  end

  @impl true
  def handle_info(:poll, state) do
    if map_size(state.sessions) == 0, do: {:noreply, state}, else: {:noreply, poll_now(state)}
  end

  def handle_info({:end_session, id}, state) do
    Logger.info("[poller] session #{id} auto-ended after duration")
    {:noreply, stop_one(state, id)}
  end

  ## Session lifecycle

  defp start_one(state, id) do
    # Reset stats only when starting from fully idle; otherwise accumulate.
    state =
      if map_size(state.sessions) == 0,
        do: %{state | polls: 0, credits: 0, actioned: MapSet.new()},
        else: state

    timer = Process.send_after(self(), {:end_session, id}, state.session_duration)
    ends_at = System.os_time(:second) + div(state.session_duration, 1000)

    Logger.info("[poller] session START #{id} — #{div(state.session_duration, 60_000)} min")

    state = %{state | sessions: Map.put(state.sessions, id, %{ends_at: ends_at, timer: timer})}
    ensure_polling(state)
  end

  defp stop_one(state, id) do
    case Map.pop(state.sessions, id) do
      {nil, _} ->
        state

      {%{timer: timer}, sessions} ->
        Process.cancel_timer(timer)
        Logger.info("[poller] session END #{id}")
        state = %{state | sessions: sessions}
        if map_size(sessions) == 0, do: go_idle(state), else: state
    end
  end

  defp stop_all(state) do
    Enum.each(state.sessions, fn {_id, %{timer: t}} -> Process.cancel_timer(t) end)
    go_idle(%{state | sessions: %{}})
  end

  defp go_idle(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    Actuator.reset()
    Logger.info("[poller] all sessions ended — #{state.polls} polls, ~#{state.credits} credits")
    %{state | poll_timer: nil}
  end

  # Start the shared poll loop if it isn't already running.
  defp ensure_polling(%{poll_timer: nil} = state), do: poll_now(state)
  defp ensure_polling(state), do: state

  ## Polling

  defp poll_now(state) do
    state =
      if state.headphones_connected do
        config = state.config_fun.()
        running = Enum.filter(config.zonesets, &Map.has_key?(state.sessions, &1.id))
        state = Enum.reduce(running, state, &poll_zoneset(&1, config, &2))
        Logger.info("[poller] poll ##{state.polls + 1} done; session ~#{state.credits} cr")
        %{state | polls: state.polls + 1}
      else
        # Paused — session timer keeps running, but no FR24 fetch / credits.
        Logger.info("[poller] poll skipped — headphones disconnected (monitoring paused)")
        state
      end

    %{state | poll_timer: Process.send_after(self(), :poll, state.poll_interval)}
  end

  defp poll_zoneset(zoneset, config, state) do
    case state.fetcher.(zoneset.monitor_box) do
      {:ok, aircraft} ->
        credits = state.credits + length(aircraft) * @credits_per_aircraft
        state = %{state | credits: credits}

        aircraft
        |> Enum.reject(&ramp?/1)
        |> Enum.reduce(state, &consider(&1, zoneset, config, &2))

      {:error, reason} ->
        Logger.warning("[poller] fetch error (#{zoneset.id}): #{inspect(reason)} (skipping)")
        state
    end
  end

  # Parked/taxiing aircraft: no position-relevant motion, don't pay attention.
  defp ramp?(ac), do: (ac.alt_ft || 0) == 0 or (ac.gspeed_kt || 0) == 0

  defp consider(ac, zoneset, config, state) do
    key = ac.hex || ac.callsign
    ceiling = zoneset.altitude_ceiling_ft || config.global_ceiling_ft

    cond do
      MapSet.member?(state.actioned, key) ->
        state

      (ac.alt_ft || 0) >= ceiling ->
        state

      # Below the zoneset's groundspeed floor — slow non-jet traffic
      # (helicopters / GA / junk) we don't want driving ANC.
      (ac.gspeed_kt || 0) < (zoneset.min_gspeed_kt || 0) ->
        state

      zoneset.trigger == :assume ->
        # Per-flight ETA from distance ÷ groundspeed (heading-independent), with
        # dwell capped (max_dwell_seconds). Falls back to the fixed assume window
        # only if ETA can't be computed (no groundspeed / no ANC zones).
        window =
          Predictor.predict_eta(ac, zoneset.anc_zones, max_dwell_seconds: config.max_dwell_seconds) ||
            assume_window(zoneset)

        dispatch(window, ac, key, config.anc_latency_seconds, state)

      true ->
        case first_window(ac, zoneset, ceiling, state.window) do
          nil -> state
          window -> dispatch(window, ac, key, config.anc_latency_seconds, state)
        end
    end
  end

  # :assume — detection in the monitor zone IS the trigger (for banking
  # departures where projecting a path into the ANC zone is unreliable). Engage
  # after a calibrated delay, hold for a calibrated duration.
  defp assume_window(zoneset) do
    enters = zoneset.assume_delay_seconds
    exits = enters + zoneset.assume_duration_seconds
    %{enters_in: enters, exits_in: exits, dwell_seconds: zoneset.assume_duration_seconds}
  end

  # The earliest engage/release window across this zoneset's ANC zones.
  defp first_window(ac, zoneset, ceiling, window_seconds) do
    accel = if zoneset.reckoning == :accelerating, do: zoneset.accel_kt_s, else: 0.0

    zoneset.anc_zones
    |> Enum.map(fn zone ->
      Predictor.predict_overflight(ac,
        noise_zone: zone,
        window_seconds: window_seconds,
        altitude_ceiling_ft: ceiling,
        accel_kt_s: accel
      )
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(& &1.enters_in, fn -> nil end)
  end

  defp dispatch(window, ac, key, latency, state) do
    # Predictions assume zero latency; fire `latency` seconds early.
    on_ms = max(round((window.enters_in - latency) * 1000), 0)
    off_ms = max(round((window.exits_in - latency) * 1000), 0)

    # Distance to entry along ground (enters_in × groundspeed) — logged so ETA
    # accuracy can be judged by eye against the FR24 map on a live pass.
    dist_km = Float.round(window.enters_in * (ac.gspeed_kt || 0) * 1.852 / 3600, 2)

    Logger.info(
      "[poller] TRIGGER #{key} alt=#{ac.alt_ft}ft gs=#{ac.gspeed_kt}kt dist=#{dist_km}km " <>
        "enters in #{round(window.enters_in)}s, dwell #{round(window.dwell_seconds)}s"
    )

    record_history(%{
      at: System.os_time(:second),
      callsign: key,
      alt_ft: ac.alt_ft,
      enters_in: round(window.enters_in),
      dwell: round(window.dwell_seconds)
    })

    Actuator.cover(on_ms, off_ms, key)
    %{state | actioned: MapSet.put(state.actioned, key)}
  end

  # History is optional (tests may run Poller without it supervised).
  defp record_history(event) do
    if Process.whereis(History), do: History.record(event)
  end

  ## Status

  defp status_of(state) do
    config = state.config_fun.()

    zonesets =
      Enum.map(config.zonesets, fn zs ->
        session = Map.get(state.sessions, zs.id)
        %{id: zs.id, name: zs.name, active: session != nil, ends_at: session && session.ends_at}
      end)

    ends = state.sessions |> Map.values() |> Enum.map(& &1.ends_at)

    %{
      active?: map_size(state.sessions) > 0,
      polls: state.polls,
      approx_credits: state.credits,
      headphones_connected: state.headphones_connected,
      session_ends_at: if(ends == [], do: nil, else: Enum.max(ends)),
      zonesets: zonesets
    }
  end

  ## Helpers

  defp zoneset_exists?(id, state), do: Enum.any?(state.config_fun.().zonesets, &(&1.id == id))

  defp enabled_ids(state) do
    state.config_fun.().zonesets |> Enum.filter(& &1.enabled) |> Enum.map(& &1.id)
  end

  defp build_state(opts) do
    fr24 = Application.get_env(:lga_predictor, :fr24, %{})
    sandbox? = Keyword.get(opts, :sandbox?, Map.get(fr24, :sandbox?, false))

    %{
      sessions: %{},
      poll_timer: nil,
      polls: 0,
      credits: 0,
      headphones_connected: true,
      actioned: MapSet.new(),
      fetcher: Keyword.get(opts, :fetcher, &default_fetch(&1, sandbox?)),
      config_fun: Keyword.get(opts, :config_fun, fn -> ConfigStore.get() end),
      window: Keyword.get(opts, :window_seconds, Application.get_env(:lga_predictor, :prediction_window_seconds, 120)),
      poll_interval: Keyword.get(opts, :poll_interval_ms, Application.get_env(:lga_predictor, :poll_interval_ms, 60_000)),
      session_duration: Keyword.get(opts, :session_duration_ms, Application.get_env(:lga_predictor, :session_duration_ms, 4 * 60 * 60 * 1000))
    }
  end

  defp default_fetch(box, sandbox?) do
    Client.positions(box, :light, sandbox?: sandbox?)
  end
end
